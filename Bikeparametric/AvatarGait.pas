unit AvatarGait;
{$mode objfpc}{$H+}
interface
uses Math, SysUtils, TripoRig, RiderDynamics;
const GAIT_HEIGHT_SAMPLES=32;
type
  TGaitHeightCurve=array[0..GAIT_HEIGHT_SAMPLES-1]of Single;
  TGaitFoot = record
    Stance: Boolean;
    Phase, Pitch, KneeFlexion, Error, SoleY, SwingCorrection: Single;
    Ankle, Contact: TTripoVec3;
  end;
  TGaitFrame = record
    Offset, Forward, Lateral: TTripoVec3;
    Feet: array[0..1] of TGaitFoot;
    Cadence, Duty, StepLength, PelvisYaw, ShoulderYaw: Single;
    Phase, Amount, Run, Scale: Single;
    VerticalVelocity, VerticalAcceleration: Single;
    WalkHeight:TGaitHeightCurve;
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
function AdvanceGaitPhase(Phase,Dt,Speed,Scale,RunBlend:Single):Single;
function AvatarGaitScale(R: TTripoRig): Single;
procedure AvatarGaitSole(R:TTripoRig;Foot:Integer;const Forward:TTripoVec3;
  out Heel,Toe:TTripoVec3);
function GaitSupport(Phase,Duty:Single):Single;
procedure GaitVerticalMotion(Phase,Duty,Rate:Single;out Height,Velocity,Acceleration:Single);
procedure GaitBodyMotion(Phase,Duty,Rate,Scale,Amount,Run:Single;
  const WalkHeight:TGaitHeightCurve;
  out Height,Velocity,Acceleration:Single);
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
    EnsureRange(1.20+Speed/Sqrt(Max(Scale,0.1))*0.055,1.32,1.80),RunBlend);
  Result:=Result/Sqrt(Max(Scale,0.1));
end;

function AdvanceGaitPhase(Phase,Dt,Speed,Scale,RunBlend:Single):Single;
begin
  { Stride travel is Speed / Frequency. Multiplying this clock by the pose
    amplitude as well makes a planted foot move slower than the actor at
    small speeds. Idle fades through stride length and limb excursion. }
  Result:=Frac(Phase+EnsureRange(Dt,0,0.1)*Sign(Speed)*
    GaitFrequency(Abs(Speed),Scale,Abs(Speed)>2.5,RunBlend));
  if Result<0 then Result:=Result+1;
end;

function GaitSupport(Phase,Duty:Single):Single;
begin
  Phase:=Frac(Phase+2);Duty:=EnsureRange(Duty,0.12,0.75);
  if Phase<Duty then Result:=Sin(Pi*Phase/Duty)*Pi/(4*Duty) else Result:=0;
end;

procedure GaitVerticalMotion(Phase,Duty,Rate:Single;out Height,Velocity,Acceleration:Single);
{ Integrate the SAME two support pulses used by the tissue/muscle solver.
  Their average is one body weight. Periodic position/velocity determine the
  integration constants; unsupported flight has acceleration -g. This also
  stays continuous while duty crosses 0.5 in the walk/run transition. }
var P,D,F,A0,V0:Double;
  function Integral1(X:Double):Double;
  begin
    if X<D then Result:=(1-Cos(Pi*X/D))*0.25 else Result:=0.5;
  end;
  function Integral2(X:Double):Double;
  begin
    if X<D then Result:=X*0.25-D*Sin(Pi*X/D)/(4*Pi)
    else Result:=X*0.5-D*0.25;
  end;
begin
  P:=Frac(Phase*2+4)*0.5;D:=EnsureRange(Duty,0.12,0.75);F:=Max(Rate,0.1);
  A0:=Integral1(0.5);V0:=-(0.75-0.5*D-A0);
  Height:=9.81/Sqr(F)*(V0*P+Integral2(P)+Integral2(P+0.5)-Integral2(0.5)-A0*P-0.5*P*P);
  Velocity:=9.81/F*(V0+Integral1(P)+Integral1(P+0.5)-A0-P);
  Acceleration:=9.81*(GaitSupport(P,D)+GaitSupport(P+0.5,D)-1);
end;

procedure GaitBodyMotion(Phase,Duty,Rate,Scale,Amount,Run:Single;
  const WalkHeight:TGaitHeightCurve;
  out Height,Velocity,Acceleration:Single);
var H,V,A,T,C0,C1,C2,C3,P0,P1,P2,P3,W:Single;I:Integer;
begin
  if Amount<=0 then begin
    Height:=WalkHeight[0];Velocity:=0;Acceleration:=0;Exit;
  end;
  if Run>=1 then begin
    GaitVerticalMotion(Phase,Duty,Rate,Height,Velocity,Acceleration);
    Height:=Height*Amount;Velocity:=Velocity*Amount;Acceleration:=Acceleration*Amount;
    Exit;
  end;
  { A periodic cubic B-spline keeps position, velocity and acceleration
    continuous through the exchange of support. Its control heights come
    from the actual leg/sole geometry, not a fixed crouch-and-bob offset. }
  T:=Frac(Phase+2)*GAIT_HEIGHT_SAMPLES;I:=Floor(T);T:=T-I;
  P0:=WalkHeight[(I+GAIT_HEIGHT_SAMPLES-1)mod GAIT_HEIGHT_SAMPLES];
  P1:=WalkHeight[I mod GAIT_HEIGHT_SAMPLES];
  P2:=WalkHeight[(I+1)mod GAIT_HEIGHT_SAMPLES];
  P3:=WalkHeight[(I+2)mod GAIT_HEIGHT_SAMPLES];
  C0:=(P0+4*P1+P2)/6;C1:=(P2-P0)*0.5;
  C2:=(P0-2*P1+P2)*0.5;C3:=(-P0+3*P1-3*P2+P3)/6;
  W:=GAIT_HEIGHT_SAMPLES*Rate;
  Height:=C0+T*(C1+T*(C2+T*C3));
  Velocity:=(C1+T*(2*C2+T*3*C3))*W;
  Acceleration:=(2*C2+T*6*C3)*W*W;
  if Run<=0 then Exit;
  GaitVerticalMotion(Phase,Duty,Rate,H,V,A);
  Height:=Blend(Height,H*Amount,Run);
  Velocity:=Blend(Velocity,V*Amount,Run);
  Acceleration:=Blend(Acceleration,A*Amount,Run);
end;
function AvatarGaitScale(R: TTripoRig): Single;
var A,B,C:Integer;
begin
  A:=R.JointIndexByName('L_Thigh');B:=R.JointIndexByName('L_Calf');C:=R.JointIndexByName('L_Foot');
  if (A<0) or (B<0) or (C<0) then Exit(1);
  Result:=(V3Len(V3Sub(R.JointBindPos(A),R.JointBindPos(B)))+
    V3Len(V3Sub(R.JointBindPos(B),R.JointBindPos(C))))/0.805;
end;
procedure AvatarGaitSole(R:TTripoRig;Foot:Integer;const Forward:TTripoVec3;
  out Heel,Toe:TTripoVec3);
var Native,Rest:TTripoMat4;Origin,P:TTripoVec3;
begin
  { Inseam moves the ankle's bind position but does not stretch its shoe.
    Measure support in the authored shoe frame, then transform its offsets
    into the current rest frame. Never infer sole depth from world Y. }
  Native:=Mat4Inverse(R.NativeInvBind[Foot]);
  Origin:=V3(Native[12],Native[13],Native[14]);
  Rest:=Mat4Mul(R.BindWorld[Foot],R.NativeInvBind[Foot]);
  P:=V3Add(Origin,V3Scale(Forward,-0.078));P.Y:=0.029;
  Heel:=V3Sub(Mat4MulPoint(Rest,P),R.JointBindPos(Foot));
  P:=V3Add(Origin,V3Scale(Forward,0.205));P.Y:=0.029;
  Toe:=V3Sub(Mat4MulPoint(Rest,P),R.JointBindPos(Foot));
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
  HeelGround,ToeGround:array[0..1]of TTripoVec3;
  Scale,LegLength,Rate,Duty,Move,Run,Travel,P,U,Pitch,Roll,
  L1,L2,Reach,LimitY,MinY,HalfWidth,StartZ,MinKnee,
  Cycle,Pace,PhaseLag,ChestRoll,ChestLean,HeelPlane,ToePlane,
  RunPace,RunDuty,SupportBase,FittedBase,Bob,Vel,Acc,SamplePhase,PlantPitch,RunStart: Single;
  I,K,Pass,FitSamples: Integer; Q,ChestQ: TTripoVec4;
  RunTarget,RunContact: TTripoVec3;
  RunOrient:TTripoVec4;
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
  function RunningPitch(T:Single):Single;
  begin
    { Neutral mild rear/midfoot landing, rather than copying the particular
      forefoot strike of one elite runner. Push-off grows with speed. }
    Result:=Curve(T,[0,0.18,0.55,1],[-6,0,5,Blend(43,53,RunPace)])*Move;
  end;
  function WalkingPitch(T:Single):Single;
  begin
    Result:=Curve(T,[0,0.17,0.65,0.82,1],[-12,0,0,20,48])*Move;
  end;
  function WalkingKnee(T:Single):Single;
  begin
    Result:=Blend(3,Curve(T,[0,0.10,0.22,0.40,0.5],[6,16,5,5,6]),Move);
  end;
  procedure Plant(Index:Integer;Along,Angle,Clearance:Single;
    out Pos,Contact:TTripoVec3;out Rotation:TTripoVec4;RollAnchor:Boolean=True);
  var Rot:TTripoVec4;H,T,Correction:TTripoVec3;HP,TP:Single;
  begin
    Rot:=QuatFromAxisAngle(Lat.X,Lat.Y,Lat.Z,DegToRad(Angle)-ArcTan(GroundSlope));
    H:=QuatRotateV3(Rot,HeelOffset[Index]);T:=QuatRotateV3(Rot,ToeOffset[Index]);
    HP:=H.Y-GroundSlope*V3Dot(H,Fwd);TP:=T.Y-GroundSlope*V3Dot(T,Fwd);
    Pos:=V3Add(Center,V3Add(V3Scale(Lat,(1-2*Index)*HalfWidth),V3Scale(Fwd,Along)));
    { Roll about the sole ALREADY aligned with the ground. On a slope,
      switching between unrotated heel/toe pivots changes the ankle's
      horizontal position even with a flat foot; roundoff then chooses a
      different pivot from frame to frame. Both corrections are zero at 0. }
    if Angle<0 then Correction:=V3Sub(HeelGround[Index],H)
    else Correction:=V3Sub(ToeGround[Index],T);
    if RollAnchor then Pos:=V3Add(Pos,V3Scale(Fwd,V3Dot(Correction,Fwd)));
    Pos.Y:=GroundSlope*V3Dot(Pos,Fwd)-Min(HP,TP)+Clearance;
    if Angle<0 then Contact:=V3Add(Pos,H) else Contact:=V3Add(Pos,T);
    Rotation:=QuatMul(Rot,Mat4ToQuat(R.BindWorld[Foot[Index]]));
  end;
  function HipAtPhase(Index:Integer;AtPhase:Single;IncludeHeight:Boolean=True):TTripoVec3;
  var Id:Integer;Rot:TTripoVec4;Origin,H:TTripoVec3;B0,V0,A0,C:Single;
  begin
    Id:=R.JointIndexByName('Pelvis');
    if Id>=0 then Origin:=R.JointBindPos(Id)
    else Origin:=V3Scale(V3Add(R.JointBindPos(Upper[0]),R.JointBindPos(Upper[1])),0.5);
    C:=2*Pi*AtPhase;
    Rot:=BodyRotation(-Blend(Blend(3.2,6.5,Pace),Blend(4,7,RunPace),Run)*Move*Cos(C),
      Blend(2.5,Blend(2.5,3.2,RunPace),Run)*Move*Sin(C),Run*Blend(2,4,RunPace));
    H:=V3Sub(R.JointBindPos(Upper[Index]),Origin);
    Result:=V3Add(Origin,QuatRotateV3(Rot,H));
    Result:=V3Add(Result,V3Scale(Lat,Blend(0.018,0.012,Run)*Scale*Move*Sin(C)));
    if IncludeHeight then begin
      GaitBodyMotion(AtPhase,Duty,Rate,Scale,Move,Run,Frame.WalkHeight,B0,V0,A0);
      Result.Y:=Result.Y+SupportBase+B0;
    end;
  end;
  function WalkSupportHeight(Index:Integer;AtPhase,Along,Angle,Knee:Single):Single;
  var Pos,Contact,Hip,D:TTripoVec3;Rot:TTripoVec4;LenA,LenB,Reach2:Single;
  begin
    Plant(Index,Along,Angle,0,Pos,Contact,Rot);
    Hip:=HipAtPhase(Index,AtPhase,False);D:=V3Sub(Pos,Hip);D.Y:=0;
    LenA:=V3Len(V3Sub(R.JointBindPos(Mid[Index]),R.JointBindPos(Upper[Index])));
    LenB:=V3Len(V3Sub(R.JointBindPos(Foot[Index]),R.JointBindPos(Mid[Index])));
    Reach2:=Sqr(LenA)+Sqr(LenB)+2*LenA*LenB*Cos(DegToRad(Knee));
    Result:=Pos.Y+Sqrt(Max(0.001,Reach2-V3Dot(D,D)))-Hip.Y;
  end;
  procedure FitWalkDuty;
  var Desired,Low,High,Trial:Single;Iteration:Integer;
    function RearFootCanStay(Candidate:Single):Boolean;
    var Side:Integer;AtPhase,LeadHeight,RearHeight,Knee:Single;
    begin
      Duty:=Candidate;Travel:=Speed/Sqrt(1+Sqr(GroundSlope))*Duty/Rate;
      Result:=True;
      for Side:=0 to 1 do begin
        AtPhase:=Frac(Duty-0.5+Side*0.5);
        Knee:=WalkingKnee(Duty-0.5);
        { Uphill loading naturally needs more knee flexion. }
        Knee:=Knee+Max(0,GroundSlope)*100*Move;
        LeadHeight:=WalkSupportHeight(Side,AtPhase,StartZ-Travel*(Duty-0.5)/Duty,
          WalkingPitch((Duty-0.5)/Duty),Knee);
        RearHeight:=WalkSupportHeight(1-Side,AtPhase,StartZ-Travel,WalkingPitch(1),3);
        if RearHeight<LeadHeight then Exit(False);
      end;
    end;
  begin
    if (Run>=1)or(Move<0.001)then Exit;
    Desired:=EnsureRange(0.68-Speed/Scale*0.035,0.58,0.68);
    if not RearFootCanStay(Desired)then begin
      { Double support ends before the trailing leg would force the new
        support knee into a crouch. Long legs do not enlarge the shoe,
        so a speed-only duty factor cannot satisfy all body proportions. }
      Low:=0.54;High:=Desired;
      for Iteration:=1 to 10 do begin
        Trial:=(Low+High)*0.5;
        if RearFootCanStay(Trial)then Low:=Trial else High:=Trial;
      end;
      Desired:=Low;
    end;
    Duty:=Blend(Desired,RunDuty,Run);
    Travel:=Speed/Sqrt(1+Sqr(GroundSlope))*Duty/Rate;
  end;
  procedure BuildWalkHeight;
  var N,Side,SupportSide,Iteration:Integer;AtPhase,FootPhase,Knee,H,Ceiling,Delta,ContactPhase:Single;
    Targets,Previous:TGaitHeightCurve;
    TakeoffHeight,LandingHeight:array[0..1]of Single;
  begin
    if Run>=1 then Exit;
    if Move<0.001 then begin
      H:=Min(WalkSupportHeight(0,0,0,0,3),WalkSupportHeight(1,0,0,0,3));
      for N:=0 to GAIT_HEIGHT_SAMPLES-1 do Frame.WalkHeight[N]:=H;
      Exit;
    end;
    for Side:=0 to 1 do begin
      ContactPhase:=Frac(Duty-Side*0.5+1);
      TakeoffHeight[Side]:=WalkSupportHeight(Side,ContactPhase,StartZ-Travel,WalkingPitch(1),3);
      ContactPhase:=Frac(1-Side*0.5);
      LandingHeight[Side]:=WalkSupportHeight(Side,ContactPhase,StartZ,WalkingPitch(0),3);
    end;
    for N:=0 to GAIT_HEIGHT_SAMPLES-1 do begin
      AtPhase:=N/GAIT_HEIGHT_SAMPLES;SupportSide:=Ord(AtPhase>=0.5);
      FootPhase:=Frac(AtPhase+SupportSide*0.5);
      Knee:=WalkingKnee(FootPhase);
      H:=WalkSupportHeight(SupportSide,AtPhase,StartZ-Travel*FootPhase/Duty,
        WalkingPitch(FootPhase/Duty),Knee);
      for Side:=0 to 1 do begin
        FootPhase:=Frac(AtPhase+Side*0.5);
        if FootPhase<Duty then begin
          Ceiling:=WalkSupportHeight(Side,AtPhase,StartZ-Travel*FootPhase/Duty,
            WalkingPitch(FootPhase/Duty),3);
          H:=Min(H,Ceiling);
        end else begin
          { Removing a contact constraint must not instantly release a
            higher pelvis position. Relax its height bound gradually, and
            anticipate the upcoming contact in the same way, especially
            on hills. The derivative of the maximum leg reach is not the
            body's velocity and must not drag it down after toe-off. }
          Delta:=FootPhase-Duty;
          Ceiling:=TakeoffHeight[Side]+0.5*9.81*Sqr(Delta/Rate);
          H:=Min(H,Ceiling);
          Delta:=FootPhase-1;
          Ceiling:=LandingHeight[Side]+0.5*9.81*Sqr(Delta/Rate);
          H:=Min(H,Ceiling);
        end;
      end;
      Frame.WalkHeight[N]:=H;
    end;
    { Interpolate the contact heights instead of averaging across their
      valleys. Averaging lifts the body past a leg's reach at handover;
      compensating for that globally would crouch the whole cycle again.
      The cyclic 1:4:1 system is diagonally dominant (contraction 1/2). }
    Targets:=Frame.WalkHeight;
    for Iteration:=1 to 12 do begin
      Previous:=Frame.WalkHeight;
      for N:=0 to GAIT_HEIGHT_SAMPLES-1 do
        Frame.WalkHeight[N]:=1.5*Targets[N]-0.25*(
          Previous[(N+GAIT_HEIGHT_SAMPLES-1)mod GAIT_HEIGHT_SAMPLES]+
          Previous[(N+1)mod GAIT_HEIGHT_SAMPLES]);
    end;
  end;
  procedure LowerWalkHeight(AtPhase,Delta:Single);
  var T,Sum:Single;Weights:array[0..3]of Single;N,Index:Integer;
  begin
    { Correct a local reach overshoot locally. Lowering the whole cycle
      for one extreme contact is what leaves every support knee bent. }
    if (Delta>=0)or(Run>=1)then Exit;
    T:=Frac(AtPhase+2)*GAIT_HEIGHT_SAMPLES;Index:=Floor(T);T:=T-Index;
    Weights[0]:=Sqr(1-T)*(1-T)/6;
    Weights[1]:=(3*T*T*T-6*T*T+4)/6;
    Weights[2]:=(-3*T*T*T+3*T*T+3*T+1)/6;
    Weights[3]:=T*T*T/6;
    Sum:=0;for N:=0 to 3 do Sum:=Sum+Sqr(Weights[N]);
    for N:=0 to 3 do
      Frame.WalkHeight[(Index+N+GAIT_HEIGHT_SAMPLES-1)mod GAIT_HEIGHT_SAMPLES]:=
        Frame.WalkHeight[(Index+N+GAIT_HEIGHT_SAMPLES-1)mod GAIT_HEIGHT_SAMPLES]+Delta*Weights[N]/Sum;
  end;
  procedure FootPath(Index:Integer;FootPhase:Single;IsRunning:Boolean;
    out Pos,Contact:TTripoVec3;out Rotation:TTripoVec4;out Angle:Single);
  const Knots:array[0..4]of Single=(0,0.24,0.56,0.82,1);
  var Points:array[0..4]of TTripoVec3;Tangents:array[0..4]of TTripoVec3;
    N,Segment:Integer;T,Span,Theta,Knee,UpperLen,LowerLen,AtPhase,StartAlong,Takeoff,Landing:Single;
    Hip,Rel,Unused:TTripoVec3;UnusedRot:TTripoVec4;
  begin
    if Move<0.001 then begin
      Angle:=0;Plant(Index,0,0,0,Pos,Contact,Rotation);Exit;
    end;
    if IsRunning then begin StartAlong:=RunStart;Takeoff:=RunningPitch(1);Landing:=RunningPitch(0) end
    else begin StartAlong:=StartZ;Takeoff:=WalkingPitch(1);Landing:=WalkingPitch(0) end;
    if FootPhase<Duty then begin
      if IsRunning then Angle:=RunningPitch(FootPhase/Duty)
      else Angle:=WalkingPitch(FootPhase/Duty);
      Plant(Index,StartAlong-Travel*FootPhase/Duty,Angle,0,Pos,Contact,Rotation);Exit;
    end;
    T:=(FootPhase-Duty)/(1-Duty);
    Plant(Index,StartAlong-Travel,Takeoff,0,Points[0],Unused,UnusedRot);
    Plant(Index,StartAlong,Landing,0,Points[4],Unused,UnusedRot);
    UpperLen:=V3Len(V3Sub(R.JointBindPos(Upper[Index]),R.JointBindPos(Mid[Index])));
    LowerLen:=V3Len(V3Sub(R.JointBindPos(Mid[Index]),R.JointBindPos(Foot[Index])));
    for N:=1 to 3 do begin
      if IsRunning then begin
        case N of
          1:begin Theta:=Blend(-10,-3,RunPace);Knee:=Blend(103,132,RunPace) end;
          2:begin Theta:=Blend(29,47,RunPace);Knee:=Blend(88,108,RunPace) end;
          else begin Theta:=Blend(30,45,RunPace);Knee:=Blend(38,56,RunPace) end;
        end;
      end else begin
        { Fold during early swing, then extend for the next heel contact.
          A fixed clearance above the ground makes a trailing leg stretch
          when the supporting hip rises, delaying recovery unnaturally. }
        case N of
          1:begin Theta:=Blend(-2,4,Pace)*Move;Knee:=Blend(20,62,Pace)*Move end;
          2:begin Theta:=Blend(6,22,Pace)*Move;Knee:=Blend(14,42,Pace)*Move end;
          else begin Theta:=Blend(10,27,Pace)*Move;Knee:=Blend(5,14,Pace)*Move end;
        end;
      end;
      AtPhase:=Frac(Duty+Knots[N]*(1-Duty)-Index*0.5+1);
      Hip:=HipAtPhase(Index,AtPhase);
      { Knee recovery and thigh swing set the ankle path. A free leg cannot
        push the pelvis down to satisfy an arbitrary low foot trajectory. }
      Rel:=V3Scale(Fwd,UpperLen*Sin(DegToRad(Theta))+LowerLen*Sin(DegToRad(Theta-Knee)));
      Rel.Y:=-UpperLen*Cos(DegToRad(Theta))-LowerLen*Cos(DegToRad(Theta-Knee));
      Points[N]:=V3Add(Hip,Rel);
      Points[N].Y:=Points[N].Y+GroundSlope*V3Dot(Points[N],Fwd);
      Points[N]:=V3Add(Points[N],V3Scale(Lat,
        V3Dot(Center,Lat)+(1-2*Index)*HalfWidth-V3Dot(Points[N],Lat)));
    end;
    Tangents[0]:=V3Scale(Fwd,-Travel*(1-Duty)/Duty);
    Tangents[0].Y:=GroundSlope*V3Dot(Tangents[0],Fwd);Tangents[4]:=Tangents[0];
    for N:=1 to 3 do Tangents[N]:=V3Scale(V3Sub(Points[N+1],Points[N-1]),
      0.70/(Knots[N+1]-Knots[N-1]));
    Segment:=0;while(Segment<3)and(T>Knots[Segment+1])do Inc(Segment);
    Span:=Knots[Segment+1]-Knots[Segment];T:=(T-Knots[Segment])/Span;
    Pos:=V3(Hermite(Points[Segment].X,Points[Segment+1].X,Tangents[Segment].X*Span,Tangents[Segment+1].X*Span,T),
      Hermite(Points[Segment].Y,Points[Segment+1].Y,Tangents[Segment].Y*Span,Tangents[Segment+1].Y*Span,T),
      Hermite(Points[Segment].Z,Points[Segment+1].Z,Tangents[Segment].Z*Span,Tangents[Segment+1].Z*Span,T));
    Angle:=Curve((FootPhase-Duty)/(1-Duty),[0,0.26,0.67,1],
      [Takeoff,12*Move,-5*Move,Landing]);
    { Pos already includes the ankle's rocker displacement. Applying it
      again while measuring clearance lifts the swing foot on a slope. }
    Plant(Index,V3Dot(V3Sub(Pos,Center),Fwd),Angle,0,Unused,Contact,Rotation,False);
    { Sole clearance is a unilateral constraint, also on sloping ground. }
    Pos.Y:=Max(Pos.Y,Unused.Y);
    Contact:=V3Add(Contact,V3Sub(Pos,Unused));
  end;
  procedure ConstrainSwing(Index:Integer);
  var Hip,D,N,T,Before,H,Tip:TTripoVec3;Rot:TTripoVec4;
    LenA,LenB,NearReach,FarReach,Distance,Plane,NormalLength,HeightLimit,Along:Single;
  begin
    if Frame.Feet[Index].Stance then Exit;
    Hip:=V3Add(R.JointWorldPos(Upper[Index]),Frame.Offset);
    Before:=Frame.Feet[Index].Ankle;D:=V3Sub(Before,Hip);
    LenA:=V3Len(V3Sub(R.JointBindPos(Mid[Index]),R.JointBindPos(Upper[Index])));
    LenB:=V3Len(V3Sub(R.JointBindPos(Foot[Index]),R.JointBindPos(Mid[Index])));
    FarReach:=Sqrt(Sqr(LenA)+Sqr(LenB)+2*LenA*LenB*Cos(DegToRad(6)));
    NearReach:=Sqrt(Sqr(LenA)+Sqr(LenB)+2*LenA*LenB*Cos(DegToRad(142)));
    Distance:=V3Len(D);
    if Distance>0.00001 then D:=V3Scale(D,EnsureRange(Distance,NearReach,FarReach)/Distance);
    Rot:=QuatMul(Orient[Index],QuatConj(Mat4ToQuat(R.BindWorld[Foot[Index]])));
    H:=QuatRotateV3(Rot,HeelOffset[Index]);Tip:=QuatRotateV3(Rot,ToeOffset[Index]);
    HeightLimit:=-Min(H.Y-GroundSlope*V3Dot(H,Fwd),Tip.Y-GroundSlope*V3Dot(Tip,Fwd));
    N:=V3Add(V3Scale(Fwd,-GroundSlope),Up);NormalLength:=V3Len(N);N:=V3Scale(N,1/NormalLength);
    Plane:=(HeightLimit-Hip.Y+GroundSlope*V3Dot(Hip,Fwd))/NormalLength;
    Along:=V3Dot(D,N);
    if Along<Plane then begin
      T:=V3Sub(D,V3Scale(N,Along));Distance:=V3Len(T);
      if Distance>0.00001 then T:=V3Scale(T,Min(1,Sqrt(Max(0,Sqr(FarReach)-Sqr(Plane)))/Distance));
      D:=V3Add(T,V3Scale(N,Plane));
    end;
    Frame.Feet[Index].Ankle:=V3Add(Hip,D);
    Frame.Feet[Index].SwingCorrection:=V3Len(V3Sub(Frame.Feet[Index].Ankle,Before));
    Frame.Feet[Index].SoleY:=Max(0,Frame.Feet[Index].Ankle.Y-
      GroundSlope*V3Dot(Frame.Feet[Index].Ankle,Fwd)-HeightLimit);
    Frame.Feet[Index].Contact:=V3Add(Frame.Feet[Index].Contact,V3Sub(Frame.Feet[Index].Ankle,Before));
  end;
  procedure Arm(Index: Integer);
  var Clavicle,Shoulder,Elbow,Hand,IndexFinger,Little,Middle: Integer;
    Swing,Flex,ArmSide,Angle,LA,LB,Elevation: Single;
    S,E,H,D1,D2,Axis,Palm,Want,BindAxis,ArmFwd,ArmLat,ArmUp: TTripoVec3; HQ,CQ: TTripoVec4;
    procedure ClearGarment(var Point:TTripoVec3;LimbRadius:Single);
    var Origin,Local:TTripoVec3;Z,X,Need,RZ:Single;
    begin
      if R.ClothingRadiusX<=0 then Exit;
      Origin:=R.JointWorldPos(R.JointIndexByName('Spine01'));
      Local:=V3Sub(Point,Origin);Z:=V3Dot(Local,ArmFwd)-0.025*Scale;
      RZ:=(R.ClothingRadiusZ+LimbRadius)*Scale;
      if Abs(Z)>=RZ then Exit;
      Need:=(R.ClothingRadiusX+LimbRadius)*Scale*Sqrt(Max(0,1-Sqr(Z/RZ)));
      X:=V3Dot(Local,ArmLat)*ArmSide;
      if X<Need then Point:=V3Add(Point,V3Scale(ArmLat,(Need-X)*ArmSide));
    end;
  begin
    Shoulder:=R.JointIndexByName(Sides[Index]+'_Upperarm');
    Elbow:=R.JointIndexByName(Sides[Index]+'_Forearm');
    Hand:=R.JointIndexByName(Sides[Index]+'_Hand');
    if (Shoulder<0) or (Elbow<0) or (Hand<0) then Exit;
    ArmSide:=1-2*Index;P:=Frac(Phase+Index*0.5);
    Swing:=-Cos(2*Pi*P)*Blend(23,Blend(25,39,RunPace),Run)*Move;
    Flex:=Blend(12+Move*(12+9*Sin(2*Pi*P)),
      Blend(78,88,RunPace)+Blend(9,15,RunPace)*Sin(2*Pi*P-0.2),Run);
    { The shoulder girdle follows the same swing as the arm. Its excursion
      is relative to the thorax, not a second world-space arm controller. }
    Frame.ShoulderProtraction[Index]:=Blend(5.5,Blend(6,10,RunPace),Run)*Move*(-Cos(2*Pi*P-0.12));
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
    ClearGarment(E,0.052);ClearGarment(H,0.036);
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
  Rate:=GaitFrequency(Speed,Scale,Running,RunBlend);
  RunPace:=Ease((Speed/Sqrt(Scale)-2.0)/5.5);
  Pace:=Ease((Speed/Scale-0.4)/1.7);
  { Shorter support at higher speed. Bound the sweep by the actual leg
    length instead of letting an unreachable trailing foot drag the body. }
  RunDuty:=Min(EnsureRange(0.43-Speed/Sqrt(Scale)*0.018,0.20,0.44),
    LegLength*Rate/Max(Speed,0.1));
  RunDuty:=EnsureRange(RunDuty,0.12,0.46);
  Duty:=Blend(EnsureRange(0.68-Speed/Scale*0.035,0.58,0.68),RunDuty,Run);
  if Speed>0 then Frame.Cadence:=120*Rate;
  Frame.StepLength:=Speed/(2*Rate);
  { Host speed is measured along the ground, while the rig's forward axis
    is horizontal. Match the host's displacement also on hills. }
  Travel:=Speed/Sqrt(1+Sqr(GroundSlope))*Duty/Rate;
  { A foot lands half a STEP ahead, not half the entire stance sweep.
    Double support makes the latter too far forward: it forces a low
    pelvis at landing and leaves the knee bent throughout midstance. }
  StartZ:=Travel/(4*Duty);RunStart:=Travel*0.36;
  HalfWidth:=Scale*Blend(0.075,0.055,Run);
  Center:=V3Scale(V3Add(R.JointBindPos(Foot[0]),R.JointBindPos(Foot[1])),0.5);
  for I:=0 to 1 do begin
    AvatarGaitSole(R,Foot[I],Fwd,HeelOffset[I],ToeOffset[I]);
    Q:=QuatFromAxisAngle(Lat.X,Lat.Y,Lat.Z,-ArcTan(GroundSlope));
    HeelGround[I]:=QuatRotateV3(Q,HeelOffset[I]);ToeGround[I]:=QuatRotateV3(Q,ToeOffset[I]);
  end;
  FitWalkDuty;Frame.Duty:=Duty;RunStart:=Travel*0.36;
  { Parametric limb fitting can move the rest ankle below the authored
    ground. Support must be allowed to RAISE the body as well as lower it;
    clamping to a negative rest offset leaves taller riders crouched even
    at zero speed. Accumulate independently, keeping predicted hips at a
    zero reference height throughout the fit. }
  SupportBase:=0;FittedBase:=MaxSingle;
  BuildWalkHeight;
  FitSamples:=16;if Run<1 then FitSamples:=64;
  for Pass:=Ord(Run>=1) to 1 do for I:=0 to 1 do begin
    L1:=V3Len(V3Sub(R.JointBindPos(Mid[I]),R.JointBindPos(Upper[I])));
    L2:=V3Len(V3Sub(R.JointBindPos(Foot[I]),R.JointBindPos(Mid[I])));
    { First correct walking reach locally, then fit the residual clearance
      and running height over the cycle. Sample more densely than the
      control points; this requires no posing, raycast or mesh work. }
    for K:=0 to FitSamples do begin
      U:=K/FitSamples;SamplePhase:=Frac(U*Duty-I*0.5+1);
      MinKnee:=Blend(3,12,Run);
      Reach:=Sqrt(Sqr(L1)+Sqr(L2)+2*L1*L2*Cos(DegToRad(MinKnee)));
      PlantPitch:=Blend(WalkingPitch(U),RunningPitch(U),Run);
      Plant(I,Blend(StartZ,RunStart,Run)-Travel*U,PlantPitch,0,Target,V,Q);
      A:=HipAtPhase(I,SamplePhase);
      V:=V3Sub(Target,A);V.Y:=0;
      LimitY:=Target.Y+Sqrt(Max(0.001,Sqr(Reach)-V3Dot(V,V)))-A.Y;
      LimitY:=LimitY-Blend(0.001,0.004,Run)*Scale*Move;
      if Pass=0 then LowerWalkHeight(SamplePhase,LimitY)
      else FittedBase:=Min(FittedBase,LimitY);
    end;
  end;
  SupportBase:=FittedBase;
  GaitBodyMotion(Phase,Duty,Rate,Scale,Move,Run,Frame.WalkHeight,Bob,Vel,Acc);
  Frame.VerticalVelocity:=Vel;Frame.VerticalAcceleration:=Acc;
  Frame.Offset:=V3Scale(Lat,Blend(0.018,0.012,Run)*Scale*Move*Sin(2*Pi*Phase));
  Frame.Offset.Y:=SupportBase+Bob;
  for I:=0 to 1 do begin
    P:=Frac(Phase+0.5*I);
    Frame.Feet[I].Phase:=P;Frame.Feet[I].Stance:=(P<Duty) or (Move<0.001);
    if Run>=1 then FootPath(I,P,True,Target,V,Orient[I],Pitch)
    else FootPath(I,P,False,Target,V,Orient[I],Pitch);
    if (Run>0)and(Run<1)then begin
      FootPath(I,P,True,RunTarget,RunContact,RunOrient,PlantPitch);
      Target:=V3Add(V3Scale(Target,1-Run),V3Scale(RunTarget,Run));
      Pitch:=Blend(Pitch,PlantPitch,Run);
    end;
    Q:=QuatFromAxisAngle(Lat.X,Lat.Y,Lat.Z,DegToRad(Pitch)-ArcTan(GroundSlope));
    A:=QuatRotateV3(Q,HeelOffset[I]);B:=QuatRotateV3(Q,ToeOffset[I]);
    HeelPlane:=A.Y-GroundSlope*V3Dot(A,Fwd);
    ToePlane:=B.Y-GroundSlope*V3Dot(B,Fwd);
    MinY:=Min(HeelPlane,ToePlane);
    LimitY:=GroundSlope*V3Dot(Target,Fwd)-MinY;
    if Frame.Feet[I].Stance then Target.Y:=LimitY else Target.Y:=Max(Target.Y,LimitY);
    Frame.Feet[I].Ankle:=Target;
    if Pitch<0 then Frame.Feet[I].Contact:=V3Add(Target,A)
    else Frame.Feet[I].Contact:=V3Add(Target,B);
    Frame.Feet[I].Pitch:=Pitch;Frame.Feet[I].SoleY:=Target.Y-LimitY;
    Orient[I]:=QuatMul(Q,Mat4ToQuat(R.BindWorld[Foot[I]]));
  end;
  { Faster gait increases pelvis/thorax counter-rotation. Distribute it
    along the spine, with a small phase lag and a stabilized head.
    Pontzer et al., J Exp Biol 2009, doi:10.1242/jeb.024927. }
  Cycle:=2*Pi*Phase;Pace:=Ease((Speed/Scale-0.4)/1.7);
  Frame.PelvisYaw:=-Blend(Blend(3.2,6.5,Pace),Blend(4,7,RunPace),Run)*Move*Cos(Cycle);
  PhaseLag:=DegToRad(Blend(65,165,Max(Pace,Run)));
  Frame.ShoulderYaw:=-Blend(Blend(3.0,7.0,Pace),Blend(4.5,8,RunPace),Run)*Move*Cos(Cycle-PhaseLag);
  Roll:=Blend(2.5,Blend(2.5,3.2,RunPace),Run)*Move*Sin(Cycle);
  ChestRoll:=-Roll*0.45;
  ChestLean:=Move*Blend(2,Blend(3.5,7,RunPace),Run)+Move*Blend(0.3,0.7,Run)*Sin(2*Cycle-0.4);
  OrientBody('Pelvis',Frame.PelvisYaw,Roll,Run*Blend(2,4,RunPace));
  OrientBody('Waist',Blend(Frame.PelvisYaw,Frame.ShoulderYaw,0.35),Roll*0.35,ChestLean*0.45);
  OrientBody('Spine01',Blend(Frame.PelvisYaw,Frame.ShoulderYaw,0.72),ChestRoll*0.5,ChestLean*0.78);
  OrientBody('Spine02',Frame.ShoulderYaw,ChestRoll,ChestLean);
  ChestQ:=BodyRotation(Frame.ShoulderYaw,ChestRoll,ChestLean);
  OrientBody('NeckTwist01',Frame.ShoulderYaw*0.28,ChestRoll*0.25,ChestLean*0.35);
  OrientBody('Head',Frame.ShoulderYaw*0.08,ChestRoll*0.05,Move*0.6);
  { Height is fitted over the entire cycle, including walking double
    support. Releasing a supporting leg must not make the body jump up. }
  for I:=0 to 1 do begin
    ConstrainSwing(I);
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
  Omega,Damping,Acceleration,Softness,Size,Amount,LoadScale:Double;
  BodyHeight,BodyVelocity,BodyAcceleration:Single;
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
      P:=Frac(Phase+(1-Side)*0.5+2);
      Loads[Side]:=GaitSupport(P,Gait.Duty);
      TotalSupport:=TotalSupport+Loads[Side];
    end;
    GaitBodyMotion(Phase,Gait.Duty,Gait.Cadence/120,Gait.Scale,Amount,Gait.Run,Gait.WalkHeight,
      BodyHeight,BodyVelocity,BodyAcceleration);
    Acceleration:=BodyAcceleration;
    { Split the vertical load between the supporting legs. The contact
      envelopes select the side; the actual body acceleration sets force. }
    LoadScale:=0;
    if TotalSupport>0.00001 then LoadScale:=Max(0,1+Acceleration/9.81)/TotalSupport;
    for Side:=0 to 1 do begin
      { Dynamics channels are right then left; gait contacts are left then
        right. A finite landing pulse avoids a frame-dependent impulse. }
      P:=Frac(Phase+(1-Side)*0.5+2);U:=P/Max(0.2,Gait.Duty);
      Loads[Side]:=Loads[Side]*LoadScale;Support:=Loads[Side];
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
