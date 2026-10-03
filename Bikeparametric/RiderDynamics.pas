unit RiderDynamics;

{$mode objfpc}{$H+}

{ Reduced articulated rider in the bicycle frame (+X forward, +Y up).
  Persistent dynamics and unilateral seat contacts; no mesh, scene or GL work.
  The analytical limb reconstruction in BikeGpuSkin consumes this solution.
  It does not advance this state or run a second body controller. }
interface

uses Math, RiderMotion;

const
  RIDER_DYNAMICS_STEP: Double = 0.008333333333333333333;
  RD_DOF = 19;
  RD_MUSCLES = 8; { right/left: gluteal, quadriceps, hamstrings, calf }

type
  TRiderDynamicVector = array[0..RD_DOF-1] of Double;
  TRiderMuscleState = array[0..RD_MUSCLES-1] of Double;
  TRiderDynamicsInput = record
    Profile: TRiderMotionProfile;
    Phase, CrankRate, BreathPhase: Double;
    Cadence, Effort, PowerW, MassKg, HeightM, Composition: Double;
    CrankRadius, CrankX, CrankY, StanceHalf, SeatHalfWidth, SeatHeight, SpeedMps: Double;
    Wheelbase, SteerAxisUp: Double;
    WeaveEnabled: Boolean;
    GoalX, GoalY, GoalZ: Double; { preferred support, relative to authored seated reference }
    SeatX, SeatY, SeatZ: Double; { saddle surface in the support frame }
    BarReach, BarWidth, TorsoLength: Double;
    HandR, HandL, FootR, FootL: Double; { contact fraction }
    LateralAccel, ForwardAccel, UpAccel, ExternalLeanDeg: Double;
    RoadPitchRad, RoadNormalAccel: Double;
    Grounded: Boolean;
  end;
  TRiderDynamicsFrame = record
    Motion: TRiderMotionFrame;
    Muscle: TRiderMuscleState;
    Tissue: array[0..3] of Double; { glute R/L, thigh R/L radial modes }
    SeatLoad, SeatCompression, PedalLoad, HandLoad: array[0..1] of Double;
    TotalLeanDeg: Double;
    RearTrackM, HeadingRad, SteerRad, YawRate: Double;
  end;
  TRiderDynamicsState = record
    Initialized: Boolean;
    Q, V, PreviousQ: TRiderDynamicVector;
    Muscle, PreviousMuscle: TRiderMuscleState;
    Tissue, TissueVelocity, PreviousTissue: array[0..3] of Double;
    SeatLoad, PedalLoad, HandLoad: array[0..1] of Double;
    FrictionX, FrictionZ, Remainder, Time: Double;
    RearTrack, Heading, Steering, SteeringVelocity: Double;
    PreviousRearTrack, PreviousHeading, PreviousSteering, WeaveAccel: Double;
    Exposure, AdjustmentTime, ComfortX, ComfortFrom, ComfortGoal: Double;
    LastInput: TRiderDynamicsInput;
    Steps: QWord;
    Frame: TRiderDynamicsFrame;
  end;

function DefaultRiderDynamicsInput: TRiderDynamicsInput;
procedure ResetRiderDynamics(var State: TRiderDynamicsState);
procedure AdvanceRiderDynamics(var State: TRiderDynamicsState;
  const Input: TRiderDynamicsInput; Dt: Double);

implementation

const
  PX=0; PY=1; PZ=2; PP=3; PA=4; PR=5;
  LP=6; LA=7; LR=8; TP=9; TA=10; TR=11;
  BR=12; SR=13; SL=14; ER=15; EL=16; CR=17; CL=18;
  G=9.80665;
  ITERATIONS=6;
  MAX_CONSTRAINTS=48;

type
  TConstraint=record
    N: Integer;
    Index: array[0..3] of Integer;
    Gradient: array[0..3] of Double;
    Target, Compliance, Lambda, MinLambda, MaxLambda: Double;
  end;

function Sat(X:Double):Double; inline;
begin Result:=EnsureRange(X,0.0,1.0) end;

function Safe(X,Lo,Hi,Fallback:Double):Double; inline;
begin
  if IsNan(X) or IsInfinite(X) then Result:=Fallback
  else Result:=EnsureRange(X,Lo,Hi);
end;

function DefaultRiderDynamicsInput:TRiderDynamicsInput;
begin
  Result:=Default(TRiderDynamicsInput);
  Result.MassKg:=75;Result.HeightM:=1.78;Result.Composition:=0.5;
  Result.CrankRadius:=0.1725;Result.StanceHalf:=0.146;
  Result.CrankX:=0.20;Result.CrankY:=-0.70;
  Result.SeatHalfWidth:=0.058;Result.BarReach:=0.46;
  Result.SeatHeight:=1.0;
  Result.Wheelbase:=1.0;Result.SteerAxisUp:=0.96;Result.WeaveEnabled:=True;
  Result.BarWidth:=0.40;Result.TorsoLength:=0.52;
  Result.HandR:=1;Result.HandL:=1;Result.FootR:=1;Result.FootL:=1;
end;

procedure ResetRiderDynamics(var State:TRiderDynamicsState);
begin State:=Default(TRiderDynamicsState) end;

function Sanitized(const Value:TRiderDynamicsInput):TRiderDynamicsInput;
begin
  Result:=Value;
  Result.MassKg:=Safe(Value.MassKg,35,180,75);
  Result.HeightM:=Safe(Value.HeightM,1.3,2.2,1.78);
  Result.Composition:=Safe(Value.Composition,0,1,0.5);
  Result.Cadence:=Safe(Value.Cadence,0,200,0);
  Result.Effort:=Safe(Value.Effort,0,3,0);
  Result.PowerW:=Safe(Value.PowerW,0,2200,0);
  Result.CrankRadius:=Safe(Value.CrankRadius,0.10,0.23,0.1725);
  Result.CrankX:=Safe(Value.CrankX,-0.3,0.5,0.20);
  Result.CrankY:=Safe(Value.CrankY,-1.2,-0.3,-0.70);
  Result.StanceHalf:=Safe(Value.StanceHalf,0.07,0.24,0.146);
  Result.SeatHalfWidth:=Safe(Value.SeatHalfWidth,0.035,0.09,0.058);
  Result.SeatHeight:=Safe(Value.SeatHeight,0.4,1.5,1.0);
  Result.SpeedMps:=Safe(Value.SpeedMps,-1,40,0);
  Result.Wheelbase:=Safe(Value.Wheelbase,0.65,1.6,1.0);
  Result.SteerAxisUp:=Safe(Value.SteerAxisUp,0.5,1.0,0.96);
  Result.TorsoLength:=Safe(Value.TorsoLength,0.3,0.75,0.52);
  Result.BarReach:=Safe(Value.BarReach,0.15,0.85,0.46);
  Result.BarWidth:=Safe(Value.BarWidth,0.20,0.80,0.40);
  Result.GoalX:=Safe(Value.GoalX,-0.45,0.45,0);
  Result.GoalY:=Safe(Value.GoalY,-0.35,0.50,0);
  Result.GoalZ:=Safe(Value.GoalZ,-0.15,0.15,0);
  Result.SeatX:=Safe(Value.SeatX,-0.5,0.5,0);
  Result.SeatY:=Safe(Value.SeatY,-0.5,0.5,0);
  Result.SeatZ:=Safe(Value.SeatZ,-0.2,0.2,0);
  Result.Phase:=Safe(Value.Phase,-10000,10000,0);
  Result.CrankRate:=Safe(Value.CrankRate,-4,4,0);
  Result.BreathPhase:=Safe(Value.BreathPhase,-10000,10000,0);
  Result.LateralAccel:=Safe(Value.LateralAccel,-12,12,0);
  Result.ForwardAccel:=Safe(Value.ForwardAccel,-8,8,0);
  Result.UpAccel:=Safe(Value.UpAccel,-8,8,0);
  Result.ExternalLeanDeg:=Safe(Value.ExternalLeanDeg,-60,60,0);
  Result.RoadPitchRad:=Safe(Value.RoadPitchRad,-0.7,0.7,0);
  Result.RoadNormalAccel:=Safe(Value.RoadNormalAccel,-8,8,0);
  Result.HandR:=Safe(Value.HandR,0,1,0);Result.HandL:=Safe(Value.HandL,0,1,0);
  Result.FootR:=Safe(Value.FootR,0,1,0);Result.FootL:=Safe(Value.FootL,0,1,0);
  Result.Profile.Standing:=Safe(Value.Profile.Standing,0,1,0);
  Result.Profile.Pedalling:=Safe(Value.Profile.Pedalling,0,1,0);
  Result.Profile.SeatedPower:=Safe(Value.Profile.SeatedPower,0,1,0);
  Result.Profile.Sprint:=Safe(Value.Profile.Sprint,0,1,0);
  Result.Profile.Breathing:=Safe(Value.Profile.Breathing,0,2,0);
  Result.Profile.AnkleDeg:=Safe(Value.Profile.AnkleDeg,0,35,0);
end;

procedure AdvanceRearTrack(var S:TRiderDynamicsState;const U:TRiderDynamicsInput;
  const LegDifference,Drive,LeanTarget:Double);
var H,Speed,Active,Omega,Excitation,MaxAccel,Accel,Target,Gain,
    OldHeading,YawRate:Double;
begin
  H:=RIDER_DYNAMICS_STEP;Speed:=Max(0.0,U.SpeedMps);
  S.PreviousRearTrack:=S.RearTrack;S.PreviousHeading:=S.Heading;
  S.PreviousSteering:=S.Steering;
  Active:=U.Profile.Standing*Drive*Min(U.HandR,U.HandL)*SmoothUnit(Speed/1.5);
  if U.Grounded or not U.WeaveEnabled then Active:=0;
  { A pedal reaction and the same measured roll state excite the steering.
    There is no second phase oscillator. Stabilizing feedback keeps the rear
    tyre close to its route; the front swings through the wheelbase lever. }
  Omega:=Max(2.0,U.Cadence*2*Pi/60);
  MaxAccel:=0.012*(Sqr(Omega)+9);
  Excitation:=Active*(-0.14*LegDifference/U.MassKg+
    0.40*G*(S.Q[BR]-LeanTarget)+0.08*G*S.V[BR]);
  Excitation:=MaxAccel*Tanh(Excitation/MaxAccel);
  Accel:=Excitation-9*S.RearTrack-6*Speed*Sin(S.Heading);
  { Steering actuator has finite response. Actual yaw and tyre tracks below
    use this SAME angle, not independent offsets painted onto the bike. }
  Target:=ArcTan(U.Wheelbase*Accel/Max(2.25,Sqr(Speed)));
  Target:=EnsureRange(Target,-DegToRad(7),DegToRad(7));
  Gain:=900;
  S.SteeringVelocity:=(S.SteeringVelocity+H*Gain*(Target-S.Steering))/(1+H*50);
  S.Steering:=S.Steering+H*S.SteeringVelocity;
  OldHeading:=S.Heading;
  YawRate:=Speed*Tan(S.Steering)/U.Wheelbase;
  S.Heading:=S.Heading+H*YawRate;
  S.RearTrack:=S.RearTrack+H*Speed*Sin((OldHeading+S.Heading)*0.5);
  S.WeaveAccel:=Speed*YawRate;
  if Speed<0.15 then begin
    { No rolling motion is possible at rest. Settle the tiny residual
      explicitly, including a simulation jump to standstill. }
    S.Heading:=S.Heading*Exp(-8*H);S.RearTrack:=S.RearTrack*Exp(-8*H);
    S.Steering:=S.Steering*Exp(-8*H);S.SteeringVelocity:=S.SteeringVelocity*Exp(-8*H);
    S.WeaveAccel:=0;
  end;
end;

procedure SolveStep(var S:TRiderDynamicsState;const U:TRiderDynamicsInput);
var
  C:array[0..MAX_CONSTRAINTS-1]of TConstraint;
  InvMass,Force,OldQ,OldV:TRiderDynamicVector;
  Count,I,J,K,Pass,SeatR,SeatL,FrictionR,FrictionL,LegSupport:Integer;
  H,H2,Mass,Size,Stand,Drive,Omega,Torque,FPeak,Theta,Right,Left,
  LegSum,LegDiff,Width,LeanTarget,Lean,GravityY,GravityZ,
  BodyMass,HandFraction,HandForce,Breath,Chest,PadK,LegK,YGoal,
  A,Den,Delta,Next,Value,Scale,Limit,Activation,Target,
  TissueK,TissueD,TissueMass,Acceleration,SeatN,Grip,HipWidth,ReachR,ReachL,Lateral:Double;

  function Add(const Indices:array of Integer;const Grad:array of Double;
    const Goal,Stiffness:Double;const Unilateral:Boolean=False):Integer;
  var N:Integer;
  begin
    Result:=Count;Inc(Count);
    C[Result]:=Default(TConstraint);
    C[Result].N:=Length(Indices);
    for N:=0 to High(Indices)do begin
      C[Result].Index[N]:=Indices[N];C[Result].Gradient[N]:=Grad[N];
    end;
    C[Result].Target:=Goal;
    if Stiffness>0 then C[Result].Compliance:=1/Stiffness;
    C[Result].MinLambda:=-1E20;C[Result].MaxLambda:=1E20;
    if Unilateral then C[Result].MinLambda:=0;
  end;

  procedure Spring(const Index:Integer;const Goal,K:Double);
  begin Add([Index],[1.0],Goal,K) end;

begin
  H:=RIDER_DYNAMICS_STEP;H2:=H*H;Count:=0;
  OldQ:=S.Q;OldV:=S.V;S.PreviousQ:=S.Q;S.PreviousMuscle:=S.Muscle;
  S.PreviousTissue:=S.Tissue;
  Mass:=U.MassKg;Size:=U.HeightM/1.78;Stand:=U.Profile.Standing;
  BodyMass:=Mass*0.68;
  Drive:=SmoothUnit(U.Cadence/35)*U.Profile.Pedalling*Min(U.FootR,U.FootL);
  if U.Grounded then Drive:=0;
  { One source of pedal effort. Phase locates the force application, not an
    authored pelvis/shoulder oscillation. The mean crank torque is P/omega. }
  Omega:=U.Cadence*2*Pi/60;Torque:=0;
  if Omega>1 then Torque:=Min(140.0,U.PowerW/Omega)*Drive;
  FPeak:=Min(Mass*G*1.8,2*Torque/U.CrankRadius);
  Theta:=U.Phase*2*Pi;
  Right:=FPeak*Max(0.0,Cos(Theta));Left:=FPeak*Max(0.0,-Cos(Theta));
  S.PedalLoad[0]:=Right;S.PedalLoad[1]:=Left;
  LegSum:=Right+Left;LegDiff:=Right-Left;Width:=U.StanceHalf;
  LeanTarget:=ArcTan2(U.LateralAccel,G*Cos(U.RoadPitchRad));
  AdvanceRearTrack(S,U,LegDiff,Drive,LeanTarget);
  Lateral:=U.LateralAccel+S.WeaveAccel;
  Lean:=S.Q[BR];
  GravityY:=G*Cos(U.RoadPitchRad)*Cos(Lean)+Lateral*Sin(Lean)+U.UpAccel+U.RoadNormalAccel;
  GravityZ:=G*Cos(U.RoadPitchRad)*Sin(Lean)-Lateral*Cos(Lean);
  HandFraction:=0.13+0.10*Stand+0.05*U.Profile.SeatedPower;
  Grip:=(U.HandR+U.HandL)*0.5;
  HandForce:=Max(0.0,BodyMass*GravityY-LegSum)*HandFraction;
  S.HandLoad[0]:=Max(0.0,HandForce*0.5+LegDiff*0.07)*U.HandR;
  S.HandLoad[1]:=Max(0.0,HandForce*0.5-LegDiff*0.07)*U.HandL;
  Breath:=Sin(U.BreathPhase*2*Pi);
  Chest:=U.Profile.Breathing*(0.28+0.32*Min(2.0,U.Effort))*Breath;

  { Deliberate comfort adjustment is an intention with a continuous target.
    It changes contact loading; it never teleports the rendered pelvis. }
  SeatN:=S.SeatLoad[0]+S.SeatLoad[1];
  if (Stand<0.05)and(not U.Grounded)and(Grip>0.95)then
    S.Exposure:=S.Exposure+H*Max(0.0,SeatN/(Mass*G)-0.20)
  else S.Exposure:=Max(0.0,S.Exposure-H);
  if (S.Exposure>14)and(S.AdjustmentTime<=0)then begin
    S.Exposure:=0;S.AdjustmentTime:=3.6;S.ComfortFrom:=S.ComfortX;
    if S.ComfortGoal<=0 then S.ComfortGoal:=0.005*Size else S.ComfortGoal:=-0.005*Size;
  end;
  if S.AdjustmentTime>0 then begin
    S.AdjustmentTime:=Max(0.0,S.AdjustmentTime-H);
    S.ComfortX:=S.ComfortFrom+(S.ComfortGoal-S.ComfortFrom)*SmoothUnit(1-S.AdjustmentTime/3.6);
  end;

  for I:=0 to RD_DOF-1 do begin InvMass[I]:=1;Force[I]:=0 end;
  for I:=PX to PZ do InvMass[I]:=1/BodyMass;
  for I:=PP to PR do InvMass[I]:=1/(Mass*0.04*Size*Size);
  for I:=LP to LR do InvMass[I]:=1/(Mass*0.011*Size*Size);
  for I:=TP to TR do InvMass[I]:=1/(Mass*0.008*Size*Size);
  { This coordinate rolls the bicycle, not a rigid bicycle+rider assembly.
    Rider mass is already carried by the pelvis/spine coordinates and their
    coupled constraints. Counting it again here suppresses standing balance. }
  InvMass[BR]:=1/(9*0.25*Size*Size);
  for I:=SR to EL do InvMass[I]:=1/(0.12*Size*Size);
  InvMass[CR]:=2;InvMass[CL]:=2;
  Force[PX]:=-BodyMass*(U.ForwardAccel+G*Sin(U.RoadPitchRad));
  Force[PY]:=-BodyMass*GravityY+LegSum+S.HandLoad[0]+S.HandLoad[1];
  Force[PZ]:=BodyMass*GravityZ;
  { Leg support acts along the hip-to-pedal lever. Its fore/aft and lateral
    components produce seat shear from the actual crank and stance geometry. }
  HipWidth:=0.085*Size;
  ReachR:=Max(0.3,0.10+S.Q[PY]-U.CrankY-U.CrankRadius*Sin(Theta));
  ReachL:=Max(0.3,0.10+S.Q[PY]-U.CrankY+U.CrankRadius*Sin(Theta));
  Force[PX]:=Force[PX]+Right*(S.Q[PX]+0.04-U.CrankX-U.CrankRadius*Cos(Theta))/ReachR+
    Left*(S.Q[PX]+0.04-U.CrankX+U.CrankRadius*Cos(Theta))/ReachL;
  Force[PZ]:=Force[PZ]+(Right/ReachR-Left/ReachL)*(HipWidth-Width);
  { Right pedal is +Z. Its downward reaction rolls the bike about +X;
    the upward force on the rider has the opposite moment (r cross F). }
  Force[PR]:=-LegDiff*Width*0.45;
  Force[PA]:=LegDiff*Width*0.10;
  Force[PP]:=-(LegSum-FPeak*0.63662)*0.025;
  Force[LA]:=-LegDiff*Width*0.035;
  Force[TA]:=-(S.HandLoad[0]-S.HandLoad[1])*U.BarWidth*0.22;
  Force[TR]:=-(S.HandLoad[0]-S.HandLoad[1])*U.TorsoLength*0.18;
  Force[BR]:=LegDiff*Width*(0.25+0.65*Stand);
  { All gravity is supported by either leg control, hands or a compressive
    seat contact. Standing has feed-forward leg support, not a seat tether. }
  LegK:=9000+61000*Stand;
  YGoal:=U.GoalY+(BodyMass*GravityY-S.HandLoad[0]-S.HandLoad[1])*Stand/LegK;
  if U.Grounded then begin
    Drive:=0;
    for I:=0 to RD_DOF-1 do Force[I]:=0;
    YGoal:=U.GoalY;
  end;
  for I:=0 to RD_DOF-1 do begin
    if I<=PZ then Scale:=7 else Scale:=11;
    if I>=CR then Scale:=35;
    S.V[I]:=S.V[I]*Exp(-Scale*H)+H*InvMass[I]*Force[I];
    S.Q[I]:=S.Q[I]+H*S.V[I];
  end;

  Spring(PX,U.GoalX+S.ComfortX*(1-Stand),6000+6000*Stand);
  LegSupport:=Add([PY],[1.0],YGoal,LegK);
  { Standing has no lateral seat tether. World balance below holds the body
    over the route while permitting the bicycle to move underneath it. }
  Spring(PZ,U.GoalZ,3500*(1-Stand)+900*Stand);
  Spring(PP,0,1500);Spring(PA,0,650);
  Spring(PR,0,1900*(1-Stand)+230*Stand);
  Spring(LP,-DegToRad(0.15*Chest),460);
  Spring(LA,0,125);Spring(LR,0,230);
  Spring(TP,-DegToRad(0.60*Chest),350);
  Spring(TA,0,100);Spring(TR,0,180);
  Spring(BR,LeanTarget,600*(1-Stand)+260*Stand);
  { Balance and bar reach couple the articulations. These are shared
    constraints, not independent post-solve counter-rotation curves. }
  Add([PR,LR,TR,BR],[1.0,1.0,1.0,1.0],LeanTarget,800*Grip+200);
  Add([PA,LA,TA],[1.0,1.0,1.0],0,260*Grip+30);
  Add([PX,PP,LP,TP],[1.0,-U.TorsoLength,-U.TorsoLength*0.68,-U.TorsoLength*0.33],
    U.GoalX,1600*Grip+100);
  Add([PZ,PR,LR,TR],[1.0,U.TorsoLength,U.TorsoLength*0.68,U.TorsoLength*0.33],
    U.GoalZ,900*Grip+100);
  { Standing balance is referenced to the unrocked trajectory: the bicycle
    moves beneath the rider. This constraint also acts on the bicycle DOF. }
  Add([PZ,BR],[1.0,(U.SeatHeight+U.GoalY)*Stand],
    U.GoalZ+(U.SeatHeight+U.GoalY)*Stand*LeanTarget,12000*Stand+1);
  { Scapulae react to the very same bar forces and thorax articulation. }
  Target:=DegToRad((S.HandLoad[0]-S.HandLoad[1])*0.018);
  Add([SR,TA],[1.0,0.35],Target,95);
  Add([SL,TA],[1.0,-0.35],-Target,95);
  Add([ER,TR],[1.0,0.35],Target*0.28+DegToRad(0.15*Chest),75);
  Add([EL,TR],[1.0,-0.35],-Target*0.28+DegToRad(0.15*Chest),75);
  PadK:=(22000+22000*U.Composition)/Size;
  Spring(CR,0,PadK);Spring(CL,0,PadK);
  SeatR:=-1;SeatL:=-1;
  { The saddle is finite. A standing pelvis ahead of it may be lower than
    its top; an infinite contact plane would raise it with saddle height. }
  { Standing intent releases the seat, progressively through the transfer.
    Its old seated contact datum is no longer a point on the lower surface
    once the hip/thigh angles change. The feet then carry the support. }
  if (not U.Grounded)and(Stand<0.999)and
    (Sqr((S.Q[PX]-U.SeatX)/0.14)+Sqr((S.Q[PZ]-U.SeatZ)/0.078)<1)then begin
    A:=250000*Sqr(1-Stand);
    SeatR:=Add([PY,PR,CR],[1.0,-U.SeatHalfWidth,1.0],U.SeatY,A,True);
    SeatL:=Add([PY,PR,CL],[1.0,U.SeatHalfWidth,1.0],U.SeatY,A,True);
  end;
  FrictionR:=Add([PX],[1.0],S.FrictionX,9000);
  FrictionL:=Add([PZ],[1.0],S.FrictionZ,5000);
  for Pass:=1 to ITERATIONS do begin
    if SeatR>=0 then SeatN:=(Max(0.0,C[SeatR].Lambda)+Max(0.0,C[SeatL].Lambda))/H2
    else SeatN:=0;
    Limit:=0.42*SeatN*H2;
    if S.AdjustmentTime>0 then Limit:=Limit*0.35;
    C[FrictionR].MinLambda:=-Limit;C[FrictionR].MaxLambda:=Limit;
    C[FrictionL].MinLambda:=-Limit;C[FrictionL].MaxLambda:=Limit;
    for I:=0 to Count-1 do begin
      A:=C[I].Compliance/H2;Den:=A;Value:=-C[I].Target;
      for J:=0 to C[I].N-1 do begin
        K:=C[I].Index[J];Value:=Value+C[I].Gradient[J]*S.Q[K];
        Den:=Den+InvMass[K]*Sqr(C[I].Gradient[J]);
      end;
      Delta:=(-Value-A*C[I].Lambda)/Max(Den,1E-12);
      Next:=EnsureRange(C[I].Lambda+Delta,C[I].MinLambda,C[I].MaxLambda);
      Delta:=Next-C[I].Lambda;C[I].Lambda:=Next;
      for J:=0 to C[I].N-1 do begin
        K:=C[I].Index[J];S.Q[K]:=S.Q[K]+InvMass[K]*C[I].Gradient[J]*Delta;
      end;
    end;
  end;
  if SeatR>=0 then begin
    S.SeatLoad[0]:=Max(0.0,C[SeatR].Lambda/H2);
    S.SeatLoad[1]:=Max(0.0,C[SeatL].Lambda/H2);
  end else begin S.SeatLoad[0]:=0;S.SeatLoad[1]:=0 end;
  Value:=C[LegSupport].Lambda/H2;
  S.PedalLoad[0]:=Right+Value*U.FootR/Max(0.01,U.FootR+U.FootL);
  S.PedalLoad[1]:=Left+Value*U.FootL/Max(0.01,U.FootR+U.FootL);
  { Plastic slip of the friction anchor at the Coulomb limit; contact release
    cannot pull the rider back to an obsolete point when sitting down again. }
  S.FrictionX:=S.Q[PX]+C[FrictionR].Lambda/H2/9000;
  S.FrictionZ:=S.Q[PZ]+C[FrictionL].Lambda/H2/5000;
  for I:=0 to RD_DOF-1 do begin
    case I of
      PX:begin A:=U.GoalX-0.04;Limit:=U.GoalX+0.04 end;
      PY:begin A:=Min(-0.025,U.GoalY-0.03);Limit:=Max(0.035,U.GoalY+0.035) end;
      PZ:begin A:=U.GoalZ-0.035;Limit:=U.GoalZ+0.035 end;
      BR:begin A:=-Pi/3;Limit:=Pi/3 end;
      CR,CL:begin A:=0;Limit:=0.024 end;
      else begin A:=-0.14;Limit:=0.14 end;
    end;
    Value:=EnsureRange(S.Q[I],A,Limit);
    S.V[I]:=(Value-OldQ[I])/H;
    if Value<>S.Q[I] then S.V[I]:=0;
    S.Q[I]:=Value;
  end;

  { Activation is effort + support. Coasting still has support tension.
    The same leg forces drive root mechanics and the visible muscle field. }
  for I:=0 to RD_MUSCLES-1 do begin
    if I<4 then Value:=Abs(S.PedalLoad[0]) else Value:=Abs(S.PedalLoad[1]);
    case I mod 4 of
      0:Activation:=0.06+0.74*Value/(Mass*G*0.65)+0.10*Stand;
      1:Activation:=0.04+0.92*Value/(Mass*G*0.65)+0.10*Stand;
      2:Activation:=0.05+0.26*Value/(Mass*G*0.65)+0.08*Stand;
      else Activation:=0.05+0.52*Value/(Mass*G*0.65)+0.14*Stand;
    end;
    if U.Grounded then Activation:=0.04;
    Target:=Sat(Activation);
    if Target>S.Muscle[I] then A:=0.045 else A:=0.10;
    S.Muscle[I]:=S.Muscle[I]+(Target-S.Muscle[I])*(1-Exp(-H/A));
  end;
  for I:=0 to 3 do begin
    J:=I mod 2;
    if I<2 then K:=J*4 else K:=J*4+1;
    TissueMass:=(1.8-1.0*U.Composition)*Size;
    TissueK:=900+1200*U.Composition+1500*S.Muscle[K];
    TissueD:=2*Sqrt(TissueK*TissueMass)*0.85;
    if I<2 then Target:=-S.Q[CR+J]*0.28 else Target:=0;
    { Bound response to actual acceleration. This is a damped mode, never
      an independent periodic oscillator. Semi-implicit damping is stable. }
    Acceleration:=EnsureRange((S.V[PY]-OldV[PY])/H,-8.0,8.0);
    S.TissueVelocity[I]:=(S.TissueVelocity[I]+H*(TissueK*(Target-S.Tissue[I])-
      TissueMass*Acceleration*0.35)/TissueMass)/(1+H*TissueD/TissueMass);
    S.Tissue[I]:=EnsureRange(S.Tissue[I]+H*S.TissueVelocity[I],-0.009,0.009);
  end;
  S.Time:=S.Time+H;Inc(S.Steps);
end;

procedure BuildFrame(var S:TRiderDynamicsState;const U:TRiderDynamicsInput);
var Q:TRiderDynamicVector;I:Integer;A,WorldRoll,WorldPitch,WorldYaw,Drive:Double;
begin
  A:=Sat(S.Remainder/RIDER_DYNAMICS_STEP);
  for I:=0 to RD_DOF-1 do Q[I]:=S.PreviousQ[I]+(S.Q[I]-S.PreviousQ[I])*A;
  S.Frame:=Default(TRiderDynamicsFrame);
  with S.Frame.Motion do begin
    X:=Q[PX];Y:=Q[PY];Z:=Q[PZ];
    Pitch:=RadToDeg(Q[PP]);Yaw:=RadToDeg(Q[PA]);Roll:=RadToDeg(Q[PR]);
    BikeLean:=RadToDeg(Q[BR])-U.ExternalLeanDeg;
    { +heading turns forward (+X) toward +Z; the upward steerer axis
      has the opposite axis-angle sign. Include its real inclination. }
    BikeSteer:=-RadToDeg(S.PreviousSteering+(S.Steering-S.PreviousSteering)*A)/U.SteerAxisUp;
    SpinePitch[0]:=RadToDeg(Q[LP]);SpineYaw[0]:=RadToDeg(Q[LA]);SpineRoll[0]:=RadToDeg(Q[LR]);
    SpinePitch[2]:=RadToDeg(Q[TP])*0.45;SpinePitch[3]:=RadToDeg(Q[TP])*0.55;
    SpineYaw[2]:=RadToDeg(Q[TA])*0.45;SpineYaw[3]:=RadToDeg(Q[TA])*0.55;
    SpineRoll[2]:=RadToDeg(Q[TR])*0.45;SpineRoll[3]:=RadToDeg(Q[TR])*0.55;
    WorldRoll:=Q[PR]+Q[LR]+Q[TR];
    WorldPitch:=Q[PP]+Q[LP]+Q[TP];WorldYaw:=Q[PA]+Q[LA]+Q[TA];
    SpineRoll[4]:=-RadToDeg(WorldRoll)*0.8;
    SpinePitch[4]:=-RadToDeg(WorldPitch);SpineYaw[4]:=-RadToDeg(WorldYaw)*0.85;
    ScapulaProtraction[0]:=RadToDeg(Q[SR]);ScapulaProtraction[1]:=RadToDeg(Q[SL]);
    ScapulaElevation[0]:=RadToDeg(Q[ER]);ScapulaElevation[1]:=RadToDeg(Q[EL]);
    Drive:=SmoothUnit(U.Cadence/35)*U.Profile.Pedalling*Min(U.FootR,U.FootL);
    if U.Grounded then Drive:=0;
    AnkleDeg:=U.Profile.AnkleDeg*Drive*(0.75+0.20*Min(2.0,U.Effort*80/Max(50.0,U.Cadence)));
  end;
  for I:=0 to RD_MUSCLES-1 do
    S.Frame.Muscle[I]:=S.PreviousMuscle[I]+(S.Muscle[I]-S.PreviousMuscle[I])*A;
  for I:=0 to 3 do S.Frame.Tissue[I]:=S.PreviousTissue[I]+(S.Tissue[I]-S.PreviousTissue[I])*A;
  S.Frame.SeatCompression[0]:=Q[CR];S.Frame.SeatCompression[1]:=Q[CL];
  S.Frame.SeatLoad:=S.SeatLoad;S.Frame.PedalLoad:=S.PedalLoad;S.Frame.HandLoad:=S.HandLoad;
  S.Frame.TotalLeanDeg:=RadToDeg(Q[BR]);
  S.Frame.RearTrackM:=S.PreviousRearTrack+(S.RearTrack-S.PreviousRearTrack)*A;
  S.Frame.HeadingRad:=S.PreviousHeading+(S.Heading-S.PreviousHeading)*A;
  S.Frame.SteerRad:=S.PreviousSteering+(S.Steering-S.PreviousSteering)*A;
  S.Frame.YawRate:=Max(0.0,U.SpeedMps)*Tan(S.Frame.SteerRad)/U.Wheelbase;
end;

procedure AdvanceRiderDynamics(var State:TRiderDynamicsState;
  const Input:TRiderDynamicsInput;Dt:Double);
var U,StepInput:TRiderDynamicsInput;Remaining,Alpha,BreathDelta:Double;I:Integer;
begin
  U:=Sanitized(Input);
  if IsNan(Dt)or IsInfinite(Dt)or(Dt<0)or(Dt>0.5)then begin
    ResetRiderDynamics(State);Dt:=0;
  end;
  if not State.Initialized then begin
    State.Initialized:=True;State.AdjustmentTime:=0;
    State.Q[PX]:=U.GoalX;State.Q[PY]:=U.GoalY;State.Q[PZ]:=U.GoalZ;
    State.Q[BR]:=ArcTan2(U.LateralAccel,G*Cos(U.RoadPitchRad));
    State.FrictionX:=U.GoalX;State.FrictionZ:=U.GoalZ;
    State.PreviousQ:=State.Q;State.LastInput:=U;
    for I:=0 to RD_MUSCLES-1 do begin State.Muscle[I]:=0.04;State.PreviousMuscle[I]:=0.04 end;
  end;
  Remaining:=State.Remainder+Max(0.0,Dt);
  while Remaining>=RIDER_DYNAMICS_STEP-1E-10 do begin
    Remaining:=Remaining-RIDER_DYNAMICS_STEP;
    StepInput:=U;
    StepInput.Phase:=U.Phase-U.CrankRate*Remaining;
    if Dt>1E-9 then begin
      Alpha:=Sat(1-Remaining/Dt);
      StepInput.GoalX:=State.LastInput.GoalX+(U.GoalX-State.LastInput.GoalX)*Alpha;
      StepInput.GoalY:=State.LastInput.GoalY+(U.GoalY-State.LastInput.GoalY)*Alpha;
      StepInput.GoalZ:=State.LastInput.GoalZ+(U.GoalZ-State.LastInput.GoalZ)*Alpha;
      StepInput.SeatX:=State.LastInput.SeatX+(U.SeatX-State.LastInput.SeatX)*Alpha;
      StepInput.SeatY:=State.LastInput.SeatY+(U.SeatY-State.LastInput.SeatY)*Alpha;
      StepInput.SeatZ:=State.LastInput.SeatZ+(U.SeatZ-State.LastInput.SeatZ)*Alpha;
      StepInput.Profile:=BlendMotionProfile(State.LastInput.Profile,U.Profile,Alpha);
      BreathDelta:=U.BreathPhase-State.LastInput.BreathPhase;
      BreathDelta:=BreathDelta-Floor(BreathDelta+0.5);
      StepInput.BreathPhase:=State.LastInput.BreathPhase+BreathDelta*Alpha;
      StepInput.Effort:=State.LastInput.Effort+(U.Effort-State.LastInput.Effort)*Alpha;
      StepInput.PowerW:=State.LastInput.PowerW+(U.PowerW-State.LastInput.PowerW)*Alpha;
      StepInput.HandR:=State.LastInput.HandR+(U.HandR-State.LastInput.HandR)*Alpha;
      StepInput.HandL:=State.LastInput.HandL+(U.HandL-State.LastInput.HandL)*Alpha;
      StepInput.LateralAccel:=State.LastInput.LateralAccel+(U.LateralAccel-State.LastInput.LateralAccel)*Alpha;
      StepInput.ForwardAccel:=State.LastInput.ForwardAccel+(U.ForwardAccel-State.LastInput.ForwardAccel)*Alpha;
      StepInput.UpAccel:=State.LastInput.UpAccel+(U.UpAccel-State.LastInput.UpAccel)*Alpha;
      StepInput.RoadPitchRad:=State.LastInput.RoadPitchRad+(U.RoadPitchRad-State.LastInput.RoadPitchRad)*Alpha;
      StepInput.RoadNormalAccel:=State.LastInput.RoadNormalAccel+(U.RoadNormalAccel-State.LastInput.RoadNormalAccel)*Alpha;
      StepInput.SpeedMps:=State.LastInput.SpeedMps+(U.SpeedMps-State.LastInput.SpeedMps)*Alpha;
    end;
    SolveStep(State,StepInput);
  end;
  State.Remainder:=Max(0.0,Remaining);
  State.LastInput:=U;BuildFrame(State,U);
end;

end.
