unit AvatarGait;
{$mode objfpc}{$H+}
interface
uses Math, SysUtils, TripoRig, RiderDynamics;
type
  TGaitFoot = record
    Stance: Boolean;
    Phase, Pitch, KneeFlexion, Error, SoleY: Single;
    Ankle, Contact: TTripoVec3;
  end;
  TGaitFrame = record
    Offset, Forward, Lateral: TTripoVec3;
    Feet: array[0..1] of TGaitFoot;
    Cadence, Duty, StepLength, PelvisYaw, ShoulderYaw: Single;
    Phase, Amount, Run, Scale: Single;
    ShoulderProtraction: array[0..1] of Single; { left, right; degrees }
  end;
  TGaitDynamicsState = record
    Initialized: Boolean;
    Phase: Double;
    Velocity: array[0..3] of Double;
    Frame: TRiderDynamicsFrame;
  end;
function GaitFrequency(Speed, Scale: Single; Running: Boolean;
  RunBlend:Single=-1): Single;
function AvatarGaitScale(R: TTripoRig): Single;
procedure PoseAvatarGait(R: TTripoRig; Phase, Speed: Single; Running: Boolean;
  out Frame: TGaitFrame; RunBlend:Single=-1; GroundSlope:Single=0);
procedure AdvanceGaitDynamics(var State:TGaitDynamicsState;
  const Gait:TGaitFrame; Effort,Composition,Dt:Single);
implementation

{ Contact-constrained, dimension-scaled approximation of adult level gait.
  Sagittal patterns and speed dependence informed by Scherpereel et al.:
  https://doi.org/10.1038/s41597-023-02840-6 and Fukuchi et al.:
  https://doi.org/10.1038/s41597-019-0124-4 . These are authored curves,
  not measured mocap or a musculoskeletal dynamics simulation. }
function Blend(A,B,T: Single): Single;
begin Result:=A+(B-A)*EnsureRange(T,0.0,1.0) end;
function Ease(T: Single): Single;
begin T:=EnsureRange(T,0.0,1.0);Result:=T*T*(3-2*T) end;
function Curve(T: Single; const Times,Values: array of Single): Single;
var I: Integer;
begin
  Result:=Values[High(Values)];
  for I:=1 to High(Times) do if T<=Times[I] then
    Exit(Blend(Values[I-1],Values[I],Ease((T-Times[I-1])/(Times[I]-Times[I-1]))));
end;
function Hermite(A,B,DA,DB,T: Single): Single;
begin Result:=(2*T*T*T-3*T*T+1)*A+(T*T*T-2*T*T+T)*DA+
  (-2*T*T*T+3*T*T)*B+(T*T*T-T*T)*DB end;
function GaitFrequency(Speed, Scale: Single; Running: Boolean;
  RunBlend:Single): Single;
begin
  if RunBlend<0 then RunBlend:=Ord(Running);
  Result:=Blend(EnsureRange(0.68+Speed/Max(Scale,0.1)*0.27,0.65,1.38),
    EnsureRange(1.18+Speed/Max(Scale,0.1)*0.10,1.25,1.95),RunBlend);
  Result:=Result/Sqrt(Max(Scale,0.1));
end;
function AvatarGaitScale(R: TTripoRig): Single;
var A,B,C:Integer;
begin
  A:=R.JointIndexByName('L_Thigh');B:=R.JointIndexByName('L_Calf');C:=R.JointIndexByName('L_Foot');
  if (A<0) or (B<0) or (C<0) then Exit(1);
  Result:=(V3Len(V3Sub(R.JointBindPos(A),R.JointBindPos(B)))+
    V3Len(V3Sub(R.JointBindPos(B),R.JointBindPos(C))))/0.805;
end;
procedure SetWorldRotation(R: TTripoRig; J: Integer; const Q: TTripoVec4);
var Parent: Integer; Pre: TTripoVec4;
begin
  if J<0 then Exit;
  Parent:=R.JointParent[J];Pre:=Mat4ToQuat(R.BindLocal[J]);
  if Parent>=0 then Pre:=QuatMul(R.JointWorldRot(Parent),Pre);
  R.SetJointDeltaQuat(J,QuatMul(QuatConj(Pre),Q));R.ComputePose;
end;

procedure PoseAvatarGait(R: TTripoRig; Phase, Speed: Single; Running: Boolean;
  out Frame: TGaitFrame; RunBlend,GroundSlope:Single);
const Sides: array[0..1] of string=('L','R');
var Lat,Fwd,Up,Center,A,B,V,Target,Pole: TTripoVec3;
  Upper,Mid,Foot,Toe: array[0..1] of Integer;
  Orient: array[0..1] of TTripoVec4;
  HeelOffset,ToeOffset: array[0..1] of TTripoVec3;
  Scale,LegLength,Rate,Duty,Move,Run,Travel,P,U,Pitch,Y,Z,Roll,
  L1,L2,Reach,LimitY,MinY,HalfWidth,HeelLen,ToeLen,Height,Side,StartZ,MinKnee,ZWalk,
  Cycle,Pace,PhaseLag,ChestRoll,ChestLean,HeelPlane,ToePlane: Single;
  I: Integer; Q,ChestQ: TTripoVec4;
  function BodyRotation(Yaw,Tilt,Lean:Single):TTripoVec4;
  begin
    Result:=QuatMul(QuatFromAxisAngle(0,1,0,DegToRad(Yaw)),
      QuatMul(QuatFromAxisAngle(Fwd.X,Fwd.Y,Fwd.Z,DegToRad(Tilt)),
      QuatFromAxisAngle(Lat.X,Lat.Y,Lat.Z,DegToRad(Lean))));
  end;
  procedure OrientBody(const Name: string; Yaw,Tilt,Lean: Single);
  var Id: Integer; Rotation: TTripoVec4;
  begin
    Id:=R.JointIndexByName(Name);if Id<0 then Exit;
    Rotation:=BodyRotation(Yaw,Tilt,Lean);
    SetWorldRotation(R,Id,QuatMul(Rotation,Mat4ToQuat(R.BindWorld[Id])));
  end;
  procedure Arm(Index: Integer);
  var Clavicle,Shoulder,Elbow,Hand,IndexFinger,Little,Middle: Integer;
    Swing,Flex,ArmSide,Angle,LA,LB,Elevation: Single;
    S,E,H,D1,D2,Axis,Palm,Want,BindAxis,ArmFwd,ArmLat,ArmUp: TTripoVec3; HQ,CQ: TTripoVec4;
  begin
    Shoulder:=R.JointIndexByName(Sides[Index]+'_Upperarm');
    Elbow:=R.JointIndexByName(Sides[Index]+'_Forearm');
    Hand:=R.JointIndexByName(Sides[Index]+'_Hand');
    if (Shoulder<0) or (Elbow<0) or (Hand<0) then Exit;
    ArmSide:=1-2*Index;P:=Frac(Phase+Index*0.5);
    Swing:=-Cos(2*Pi*P)*Blend(23,36,Run)*Move;
    Flex:=Blend(12+Move*(12+9*Sin(2*Pi*P)),82+12*Sin(2*Pi*P-0.2),Run);
    { The shoulder girdle follows the same swing as the arm. Its excursion
      is relative to the thorax, not a second world-space arm controller. }
    Frame.ShoulderProtraction[Index]:=Blend(5.5,9,Run)*Move*(-Cos(2*Pi*P-0.12));
    Elevation:=Move*(0.6+Blend(0.8,1.7,Run)*Sin(2*Pi*P-0.3));
    Clavicle:=R.JointIndexByName(Sides[Index]+'_Clavicle');
    if Clavicle>=0 then begin
      CQ:=QuatMul(QuatFromAxisAngle(Up.X,Up.Y,Up.Z,
        DegToRad(-ArmSide*Frame.ShoulderProtraction[Index])),
        QuatFromAxisAngle(Fwd.X,Fwd.Y,Fwd.Z,DegToRad(ArmSide*Elevation)));
      SetWorldRotation(R,Clavicle,QuatMul(ChestQ,QuatMul(CQ,Mat4ToQuat(R.BindWorld[Clavicle]))));
    end;
    ArmFwd:=QuatRotateV3(ChestQ,Fwd);ArmLat:=QuatRotateV3(ChestQ,Lat);
    ArmUp:=QuatRotateV3(ChestQ,Up);
    LA:=V3Len(V3Sub(R.JointBindPos(Elbow),R.JointBindPos(Shoulder)));
    LB:=V3Len(V3Sub(R.JointBindPos(Hand),R.JointBindPos(Elbow)));
    D1:=V3Norm(V3Add(V3Add(V3Scale(ArmFwd,Sin(DegToRad(Swing))),
      V3Scale(ArmUp,-Cos(DegToRad(Swing)))),V3Scale(ArmLat,ArmSide*Blend(0.065,0.09,Run))));
    D2:=V3Norm(V3Add(V3Add(V3Scale(ArmFwd,Sin(DegToRad(Swing+Flex))),
      V3Scale(ArmUp,-Cos(DegToRad(Swing+Flex)))),
      V3Scale(ArmLat,ArmSide*Blend(0.02,-0.16*Max(0,Sin(DegToRad(Swing+Flex))),Run))));
    S:=R.JointWorldPos(Shoulder);E:=V3Add(S,V3Scale(D1,LA));H:=V3Add(E,V3Scale(D2,LB));
    R.SolveTwoBone(Shoulder,Elbow,Hand,H,V3Sub(E,S),False);
    Axis:=V3Norm(V3Sub(R.JointWorldPos(Hand),R.JointWorldPos(Elbow)));
    BindAxis:=V3Norm(V3Sub(R.JointBindPos(Hand),R.JointBindPos(Elbow)));
    HQ:=QuatMul(QuatFromTo(BindAxis,Axis),Mat4ToQuat(R.BindWorld[Hand]));
    IndexFinger:=R.JointIndexByName(Sides[Index]+'_Index1');
    Little:=R.JointIndexByName(Sides[Index]+'_Little1');
    Middle:=R.JointIndexByName(Sides[Index]+'_Middle1');
    if (IndexFinger>=0) and (Little>=0) and (Middle>=0) then begin
      Palm:=V3Norm(V3Cross(V3Sub(R.JointBindPos(IndexFinger),R.JointBindPos(Little)),
        V3Sub(R.JointBindPos(Middle),R.JointBindPos(Hand))));
      Palm:=V3Scale(Palm,ArmSide);
      Palm:=QuatRotateV3(QuatMul(HQ,QuatConj(Mat4ToQuat(R.BindWorld[Hand]))),Palm);
      Palm:=V3Norm(V3Sub(Palm,V3Scale(Axis,V3Dot(Palm,Axis))));
      { Index-to-little crossed with wrist-to-middle describes the BACK of
        the hand in this rig. Point it outwards: palms face the thighs and
        thumbs point forwards, rather than adding 180 degrees of pronation. }
      Want:=V3Scale(ArmLat,ArmSide);Want:=V3Norm(V3Sub(Want,V3Scale(Axis,V3Dot(Want,Axis))));
      Angle:=ArcTan2(V3Dot(Axis,V3Cross(Palm,Want)),V3Dot(Palm,Want));
      HQ:=QuatMul(QuatFromAxisAngle(Axis.X,Axis.Y,Axis.Z,Angle),HQ);
    end;
    SetWorldRotation(R,Hand,HQ);
    R.DistributeForearmTwist(Sides[Index]+'_');
  end;
begin
  Frame:=Default(TGaitFrame);R.ResetPose;R.ComputePose;
  GroundSlope:=EnsureRange(GroundSlope,-1,1);
  for I:=0 to 1 do begin
    Upper[I]:=R.JointIndexByName(Sides[I]+'_Thigh');Mid[I]:=R.JointIndexByName(Sides[I]+'_Calf');
    Foot[I]:=R.JointIndexByName(Sides[I]+'_Foot');Toe[I]:=R.JointIndexByName(Sides[I]+'_ToeBase');
    if (Upper[I]<0) or (Mid[I]<0) or (Foot[I]<0) then Exit;
  end;
  Lat:=V3Sub(R.JointBindPos(Upper[0]),R.JointBindPos(Upper[1]));Lat.Y:=0;Lat:=V3Norm(Lat);
  Up:=V3(0,1,0);Fwd:=V3Norm(V3Cross(Lat,Up));
  Frame.Forward:=Fwd;Frame.Lateral:=Lat;
  LegLength:=V3Len(V3Sub(R.JointBindPos(Upper[0]),R.JointBindPos(Mid[0])))+
    V3Len(V3Sub(R.JointBindPos(Mid[0]),R.JointBindPos(Foot[0])));
  Scale:=LegLength/0.805;Speed:=Max(0,Speed);Move:=Ease(Speed/(0.45*Scale));
  if RunBlend<0 then RunBlend:=Ord(Running);
  Run:=EnsureRange(RunBlend,0,1)*Move;Phase:=Frac(Phase);
  Frame.Phase:=Phase;Frame.Amount:=Move;Frame.Run:=Run;Frame.Scale:=Scale;
  Rate:=GaitFrequency(Speed,Scale,Running,RunBlend);Duty:=Blend(EnsureRange(0.68-Speed/Scale*0.035,0.58,0.68),
    EnsureRange(0.48-Speed/Scale*0.026,0.26,0.46),Run);
  Frame.Cadence:=120*Rate*Move;Frame.Duty:=Duty;Frame.StepLength:=Speed/(2*Rate);
  Travel:=Min(Speed*Duty/Rate,LegLength*1.4);
  StartZ:=Travel*Blend(0.5,0.35,Run);
  HalfWidth:=Scale*Blend(0.075,0.055,Run);
  Center:=V3Scale(V3Add(R.JointBindPos(Foot[0]),R.JointBindPos(Foot[1])),0.5);
  Frame.Offset:=V3Scale(Lat,Blend(0.018,0.012,Run)*Scale*Move*Sin(2*Pi*Phase));
  Frame.Offset.Y:=Scale*Blend(-0.029-Move*0.016*(1+Cos(4*Pi*Phase)),
    -0.04-0.022*(1+Cos(4*Pi*(Phase-Duty*0.5))),Run);
  for I:=0 to 1 do begin
    P:=Frac(Phase+0.5*I);Side:=1-2*I;
    Frame.Feet[I].Phase:=P;Frame.Feet[I].Stance:=(P<Duty) or (Move<0.001);
    Pitch:=0;Y:=0;
    if P<Duty then begin
      U:=P/Duty;Z:=StartZ-Travel*U;
      Pitch:=Blend(Curve(U,[0,0.17,0.65,1],[-12,0,0,36]),
        Curve(U,[0,0.25,0.65,1],[-3,0,6,45]),Run)*Move;
    end else begin
      U:=(P-Duty)/(1-Duty);
      { Short follow-through after toe-off and before landing prevents the
        large backwards overshoot of a single cubic at sprinting speeds. }
      if U<0.2 then
        Z:=Hermite(StartZ-Travel,StartZ-Travel-0.045*Scale*Move,-Travel*(1-Duty)/Duty*0.2,0,U/0.2)
      else if U<0.82 then
        Z:=Hermite(StartZ-Travel-0.045*Scale*Move,StartZ+0.025*Scale*Move,0,0,(U-0.2)/0.62)
      else Z:=Hermite(StartZ+0.025*Scale*Move,StartZ,0,-Travel*(1-Duty)/Duty*0.18,(U-0.82)/0.18);
      ZWalk:=Hermite(StartZ-Travel,StartZ,-Travel*(1-Duty)/Duty,-Travel*(1-Duty)/Duty,U);
      Z:=Blend(ZWalk,Z,Run);
      Y:=Scale*Blend(0.105,0.32,Run)*Move*Curve(U,[0,0.28,0.65,1],[0,1,0.65,0]);
      Pitch:=Blend(Curve(U,[0,0.3,0.75,1],[36,-3,-5,-12]),
        Curve(U,[0,0.3,0.65,1],[45,12,-7,-3]),Run)*Move;
    end;
    Height:=R.JointBindPos(Foot[I]).Y-0.029*Scale;
    ToeLen:=0.205*Scale;HeelLen:=0.078*Scale;
    HeelOffset[I]:=V3Add(V3Scale(Fwd,-HeelLen),V3(0,-Height,0));
    ToeOffset[I]:=V3Add(V3Scale(Fwd,ToeLen),V3(0,-Height,0));
    { Fit each sole to the support plane, keeping the body upright. Reuse
      the host's measured forward grade; no extra terrain queries are needed. }
    Q:=QuatFromAxisAngle(Lat.X,Lat.Y,Lat.Z,DegToRad(Pitch)-ArcTan(GroundSlope));
    A:=QuatRotateV3(Q,HeelOffset[I]);B:=QuatRotateV3(Q,ToeOffset[I]);
    HeelPlane:=A.Y-GroundSlope*V3Dot(A,Fwd);
    ToePlane:=B.Y-GroundSlope*V3Dot(B,Fwd);
    MinY:=Min(HeelPlane,ToePlane);
    Target:=V3Add(Center,V3Add(V3Scale(Lat,Side*HalfWidth),V3Scale(Fwd,Z)));
    if HeelPlane<ToePlane then V:=V3Sub(HeelOffset[I],A) else V:=V3Sub(ToeOffset[I],B);
    Target:=V3Add(Target,V3Scale(Fwd,V3Dot(V,Fwd)));
    Target.Y:=GroundSlope*V3Dot(Target,Fwd)-MinY+Y;Frame.Feet[I].Ankle:=Target;
    if HeelPlane<ToePlane then Frame.Feet[I].Contact:=V3Add(Target,A)
    else Frame.Feet[I].Contact:=V3Add(Target,B);
    Frame.Feet[I].Pitch:=Pitch;Frame.Feet[I].SoleY:=Y;
    Orient[I]:=QuatMul(Q,Mat4ToQuat(R.BindWorld[Foot[I]]));
  end;
  { Faster gait increases pelvis/thorax counter-rotation. Distribute it
    along the spine, with a small phase lag and a stabilized head.
    Pontzer et al., J Exp Biol 2009, doi:10.1242/jeb.024927. }
  Cycle:=2*Pi*Phase;Pace:=Ease((Speed/Scale-0.4)/1.7);
  Frame.PelvisYaw:=-Blend(3.2,6.5,Pace)*Move*Cos(Cycle);
  PhaseLag:=DegToRad(Blend(65,165,Max(Pace,Run)));
  Frame.ShoulderYaw:=-Blend(3.0,7.0,Max(Pace,Run))*Move*Cos(Cycle-PhaseLag);
  Roll:=Blend(2.5,3.3,Run)*Move*Sin(Cycle);
  ChestRoll:=-Roll*0.45;
  ChestLean:=Move*Blend(2,8,Run)+Move*Blend(0.3,0.8,Run)*Sin(2*Cycle-0.4);
  OrientBody('Pelvis',Frame.PelvisYaw,Roll,Run*2);
  OrientBody('Waist',Blend(Frame.PelvisYaw,Frame.ShoulderYaw,0.35),Roll*0.35,ChestLean*0.45);
  OrientBody('Spine01',Blend(Frame.PelvisYaw,Frame.ShoulderYaw,0.72),ChestRoll*0.5,ChestLean*0.78);
  OrientBody('Spine02',Frame.ShoulderYaw,ChestRoll,ChestLean);
  ChestQ:=BodyRotation(Frame.ShoulderYaw,ChestRoll,ChestLean);
  OrientBody('NeckTwist01',Frame.ShoulderYaw*0.28,ChestRoll*0.25,ChestLean*0.35);
  OrientBody('Head',Frame.ShoulderYaw*0.08,ChestRoll*0.05,Move*0.6);
  { Lower the pelvis only as needed to keep supporting knees within reach.
    The floor constraint takes priority over stretching either bone. }
  for I:=0 to 1 do begin
    A:=R.JointWorldPos(Upper[I]);Target:=V3Sub(Frame.Feet[I].Ankle,Frame.Offset);
    L1:=V3Len(V3Sub(R.JointBindPos(Mid[I]),R.JointBindPos(Upper[I])));
    L2:=V3Len(V3Sub(R.JointBindPos(Foot[I]),R.JointBindPos(Mid[I])));
    MinKnee:=6;
    if Frame.Feet[I].Stance then
      MinKnee:=Curve(Frame.Feet[I].Phase/Duty,[0,0.20,0.55,1],[6,15,6,6]);
    MinKnee:=Blend(Blend(6,MinKnee,Move),18,Run);
    Reach:=Sqrt(Sqr(L1)+Sqr(L2)+2*L1*L2*Cos(DegToRad(MinKnee)));
    V:=V3Sub(Target,A);V.Y:=0;
    LimitY:=Frame.Feet[I].Ankle.Y+Sqrt(Max(0.001,Sqr(Reach)-V3Dot(V,V)))-A.Y;
    Frame.Offset.Y:=Min(Frame.Offset.Y,LimitY);
  end;
  for I:=0 to 1 do begin
    Target:=V3Sub(Frame.Feet[I].Ankle,Frame.Offset);
    Pole:=V3Add(Fwd,V3Scale(Lat,(1-2*I)*0.025));
    R.SolveTwoBone(Upper[I],Mid[I],Foot[I],Target,Pole,False);
    SetWorldRotation(R,Foot[I],Orient[I]);
    if Toe[I]>=0 then begin
      Pitch:=-Max(0,Frame.Feet[I].Pitch)*0.72;
      R.ApplyWorldPitchByIndex(Toe[I],Lat.X,Lat.Y,Lat.Z,DegToRad(Pitch));
    end;
    A:=V3Norm(V3Sub(R.JointWorldPos(Upper[I]),R.JointWorldPos(Mid[I])));
    B:=V3Norm(V3Sub(R.JointWorldPos(Foot[I]),R.JointWorldPos(Mid[I])));
    Frame.Feet[I].KneeFlexion:=180-RadToDeg(ArcCos(EnsureRange(V3Dot(A,B),-1.0,1.0)));
    Frame.Feet[I].Error:=V3Len(V3Sub(R.JointWorldPos(Foot[I]),Target));
  end;
  Arm(0);Arm(1);R.ApplyHandGrip(0.17+Run*0.2,0.17+Run*0.2);R.ComputePose;
end;

procedure AdvanceGaitDynamics(var State:TGaitDynamicsState;
  const Gait:TGaitFrame; Effort,Composition,Dt:Single);
var Steps,Step,Side,I,Channel:Integer;
  H,Delta,Phase,P,U,Support,TotalSupport,Activation,Target,Rate,
  Omega,Damping,Acceleration,Softness,Size,Amount:Double;
  Loads:array[0..1]of Double;
begin
  if not State.Initialized then begin
    State:=Default(TGaitDynamicsState);State.Initialized:=True;State.Phase:=Gait.Phase;
    for I:=0 to 7 do State.Frame.Muscle[I]:=0.04;
  end;
  Dt:=EnsureRange(Dt,0,0.1);if Dt<=0 then Exit;
  Delta:=Gait.Phase-State.Phase;
  if Delta>0.5 then Delta:=Delta-1 else if Delta< -0.5 then Delta:=Delta+1;
  Steps:=Max(1,Ceil(Dt*240));H:=Dt/Steps;
  Softness:=1-EnsureRange(Composition,0,1);Size:=Max(0.6,Gait.Scale);
  Amount:=Gait.Amount;
  for Step:=1 to Steps do begin
    Phase:=State.Phase+Delta*Step/Steps;TotalSupport:=0;
    for Side:=0 to 1 do begin
      { Dynamics channels are right then left; gait contacts are left then
        right. A finite landing pulse avoids a frame-dependent impulse. }
      P:=Frac(Phase+(1-Side)*0.5+2);U:=P/Max(0.2,Gait.Duty);
      if U<1 then Support:=Sin(Pi*U)*Pi/(4*Gait.Duty) else Support:=0;
      Loads[Side]:=Support;TotalSupport:=TotalSupport+Support;
      for I:=0 to 3 do begin
        case I of
          0:Activation:=Support*0.38*Max(0,1-U*0.8);
          1:Activation:=Support*0.48*Max(0,1-U*0.7);
          2:Activation:=0.22*Max(0,Cos(2*Pi*(P-0.90)));
          else Activation:=Support*0.55*Ease((U-0.3)/0.45);
        end;
        Channel:=Side*4+I;
        Target:=EnsureRange(0.04+Amount*Activation*(0.6+0.4*Effort),0,1);
        Rate:=0.08;if Target>State.Frame.Muscle[Channel]then Rate:=0.035;
        State.Frame.Muscle[Channel]:=State.Frame.Muscle[Channel]+
          (Target-State.Frame.Muscle[Channel])*(1-Exp(-H/Rate));
      end;
    end;
    { Four damped radial tissue modes use the existing muscle envelopes and
      shader normal correction. Landing/support accelerates the skeleton;
      the soft tissue lags and rings down. No saddle contact while on foot. }
    Acceleration:=(TotalSupport-1)*9.81*Amount;
    for I:=0 to 3 do begin
      Side:=I mod 2;Channel:=Side*4+Ord(I>=2);
      Omega:=2*Pi*(5.0-1.5*Softness+1.8*State.Frame.Muscle[Channel])/Sqrt(Size);
      Damping:=0.25+0.13*(1-Softness)+0.16*State.Frame.Muscle[Channel];
      Target:=0.0015*Size*Amount*(Loads[Side]-0.5)*(0.35+0.65*Softness);
      Rate:=Blend(0.12,0.24,Gait.Run)*(0.45+0.55*Softness);
      State.Velocity[I]:=(State.Velocity[I]+H*(Sqr(Omega)*(Target-State.Frame.Tissue[I])-
        Acceleration*Rate))/(1+2*Damping*Omega*H);
      State.Frame.Tissue[I]:=EnsureRange(State.Frame.Tissue[I]+H*State.Velocity[I],-0.012*Size,0.012*Size);
    end;
  end;
  State.Phase:=Gait.Phase;
end;
end.
