function PedalingMuscleDemand(const Group:Integer;const Phase:Double):Double;
 function Pulse(const PeakDeg,Sharpness:Double):Double;
 begin Result:=Exp(Sharpness*(Cos(2*Pi*Phase-DegToRad(PeakDeg))-1))end;
begin
 { Authored, periodic recruitment envelopes, not EMG measurements or forces.
   Extensors load the downstroke; biarticular muscles transfer load around the
   transitions; hip flexors/dorsiflexors recover the leg. See pedaling-reference. }
 case Group of
  1:Result:=0.04+0.94*Pulse(55,2.4);      // vasti
  2:Result:=0.05+0.80*Pulse(355,2.5);     // rectus femoris
  3:Result:=0.06+0.67*Pulse(150,1.9);     // hamstrings, late downstroke
  4:Result:=0.05+0.90*Pulse(45,2.0);      // gluteus maximus
  5:Result:=0.18+0.18*Pulse(70,1.5);      // pelvic stabilizers
  6:Result:=0.05+0.72*Pulse(130,2.0);     // gastrocnemius
  7:Result:=0.05+0.78*Pulse(120,2.2);     // soleus
  8:Result:=0.04+0.60*Pulse(300,2.2);     // tibialis anterior
  9:Result:=0.10+0.18*Pulse(130,1.5);
  19:Result:=0.04+0.65*Pulse(300,2.0);    // hip flexors
  else Result:=0;
 end;
end;

procedure TNeuralRider.UpdateMuscleDemand;
var S,B:Integer;Suffix:string;FootY:array[0..1]of Double;P,Axis:TVec3;Elevation:Double;
begin
 for S:=0 to 1 do begin
  Suffix:='.L';if S=1 then Suffix:='.R';B:=BoneIndex('talus'+Suffix);
  P:=RPoint(Transforms[B],Bones[B].Pivot);FootY[S]:=P.Y;
 end;
 for S:=0 to 1 do begin
  LegSupport[S]:=1-Smooth01((FootY[S]-Min(FootY[0],FootY[1])-0.015)/0.075);
  LegDemand[S]:=LegSupport[S]*(0.72*Smooth01(Pose.Knee[S]/110)+0.28*Smooth01(Max(0,Pose.Hip[S])/100));
  Suffix:='.L';if S=1 then Suffix:='.R';B:=BoneIndex('humerus'+Suffix);
  Axis:=SafeUnit(Sub(Bones[B].Tip,Bones[B].Pivot));P:=QRotate(QMul(QInverse(Transforms[BoneIndex('T1')].Q),Transforms[B].Q),Axis);
  Elevation:=Max(0,RadToDeg(ArcCos(EnsureRange(-P.Y,-1.0,1.0))-ArcCos(EnsureRange(-Axis.Y,-1.0,1.0))));
  ArmElevation[S]:=Elevation;ArmDemand[S]:=Smooth01(Elevation/100)*(0.65+0.35*Sin(DegToRad(Min(180,Elevation))));
 end;
end;

function TNeuralRider.MuscleActivationFor(const Index:Integer;const Ratio:Double):Double;
var S,K:Integer;D,Flex,Hip,FreeLeg,Forward,Side,Effort,CycleDemand:Double;
begin
 S:=Muscles[Index].ActionSide;K:=Muscles[Index].ActionGroup;
 Flex:=Smooth01(Max(0,Pose.Knee[S])/110);Hip:=Smooth01(Max(0,Pose.Hip[S])/100);
 FreeLeg:=1-LegSupport[S];Forward:=Smooth01(Max(0,Pose.ShoulderForward[S])/90);Side:=Smooth01(Max(0,Pose.Shoulder[S])/90);
 D:=Max(0,1-Ratio)*3;
 case K of
  1:D:=LegDemand[S];
  2:D:=0.75*LegDemand[S]+0.55*FreeLeg*Hip;
  3:D:=0.25*LegDemand[S]+FreeLeg*Flex;
  4:D:=LegSupport[S]*(0.80*Hip+0.20*Flex)+Smooth01(Max(0,-Pose.Hip[S])/35)*0.5;
  5:D:=LegSupport[S]*(0.45*(1-LegSupport[1-S])+0.25*LegDemand[S])+0.6*Smooth01(Abs(Pose.HipSide[S])/40);
  6:D:=0.30*LegDemand[S]+0.65*Smooth01(Max(0,-Pose.Ankle[S])/35)+0.20*FreeLeg*Flex;
  7:D:=0.45*LegDemand[S]+0.75*Smooth01(Max(0,-Pose.Ankle[S])/35);
  8:D:=0.55*Smooth01(Max(0,Pose.Ankle[S])/35);
  9:D:=0.35*LegDemand[S]+0.30*Smooth01(Max(0,-Pose.HipSide[S])/25);
  10:D:=ArmDemand[S]*(0.25+0.75*Forward);
  11:D:=ArmDemand[S]*(0.45+0.55*Side);
  12:D:=0.25*ArmDemand[S]+0.70*Smooth01(Max(0,-Pose.ShoulderForward[S])/40)+0.30*Smooth01(Max(0,Pose.ShoulderTwist[S])/60);
  13:D:=0.55*Forward+0.25*Smooth01(Max(0,-Pose.ShoulderTwist[S])/50);
  14:D:=0.20*ArmDemand[S]+0.65*Smooth01(Max(0,-Pose.ShoulderForward[S])/45);
  15:D:=0.70*ArmDemand[S];
  16:D:=0.75*ArmDemand[S]+0.20*Forward;
  17:D:=Smooth01(Max(0,Pose.Elbow[S])/120);
  18:D:=0.16*Smooth01(Max(0,Pose.Elbow[S])/120)+0.25*ArmDemand[S];
  19:D:=FreeLeg*Hip+0.10*LegDemand[S];
  20:D:=Smooth01(Max(0,Pose.PelvisTilt+Pose.SpineBend)/55)*0.80;
  21:D:=0.25*LegDemand[S]+0.45*Smooth01(Max(0,-Pose.Ankle[S])/35)+0.35*Smooth01(Abs(Pose.AnkleRoll[S])/20);
 end;
 if(Pose.Pedaling>0)and((K in[1..9])or(K=19))then begin
  CycleDemand:=PedalingMuscleDemand(K,Pose.PedalPhase+S*0.5);
  D:=D+(CycleDemand-D)*EnsureRange(Pose.Pedaling,0.0,1.0);
 end;
 Effort:=EnsureRange(Pose.Effort,0.0,1.0);Muscles[Index].AutoActivation:=Effort*EnsureRange(D,0.0,1.0);
 Result:=1-(1-EnsureRange(Muscles[Index].ManualActivation,0.0,1.0))*(1-Muscles[Index].AutoActivation);
 if DynamicFrameActive and(Pose.Pedaling>0.99)and(K in[1,2,4,6,7])then
  Result:=EnsureRange(Result+PedalPress[S],0.0,1.0);
end;
