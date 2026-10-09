unit AvatarHemDynamics;
{$mode objfpc}{$H+}
interface
uses CastleVectors;
const
  HemColumns=9;
  HemRing=HemColumns*2;
  HemTorsoRows=4;
  HemSkirtRows=4;
  HemRows=HemTorsoRows+HemSkirtRows+1;
  HemPoints=HemRing*HemRows;
  HemMovingPoints=HemRing*(HemRows-1);
type
  THemPositions=array[0..HemPoints-1]of TVector3;
  THemOffsets=array[0..HemMovingPoints-1]of TVector3;
  THemEdge=record A,B:Integer;Length,Compliance,Lambda:Single end;
  { A persistent, reduced garment cage, from the armhole seam to the hem.
    Only its free offsets go to the GPU;
    no rendered vertices, skeleton solve or GPU readback are involved. }
  TAvatarHemDynamics=class
  private
    FRest,FTarget,FLastTarget,FStepTarget,FPosition,FPrevious,FVelocity:THemPositions;
    FRestOutside,FStepOutside:THemPositions;
    FMetric:THemPositions;
    FTouched:array[0..HemPoints-1]of Boolean;
    FBodyCentre,FBodyX,FBodyY,FBodyZ:array[0..HemTorsoRows]of TVector3;
    FBodyRX,FBodyRZ:array[0..HemTorsoRows]of Single;
    FHipFrame,FHipInverse:TMatrix4;
    FHipCentre,FHipRadii:TVector3;
    FHipValid:Boolean;
    FEdges:array of THemEdge;
    FFrame:TMatrix4;
    FLastSpeed,FScale,FLength,FDensity,FBuild:Single;
    FTime,FRemainder:Double;
    FValid,FVent:Boolean;
    FLegA,FLegB:array[0..3]of TVector3;
    FLastLegA,FLastLegB:array[0..3]of TVector3;
    FLastLegValid:array[0..3]of Boolean;
    FLegRadius,FLegTipRadius:array[0..3]of Single;
    FLegWidth,FLegTipWidth,FLegInvLengthSqr:array[0..3]of Single;
    FLegInnerWidth,FLegTipInnerWidth:array[0..3]of Single;
    FLegAxis,FLegX,FLegY,FLegZ:array[0..3]of TVector3;
    procedure Edge(A,B:Integer;Compliance:Single);
    procedure ProjectLegEdge(A,B:Integer);
    procedure ProjectBody(var P:TVector3);
    procedure ProjectLegs(Index:Integer;FinalPass:Boolean=False);
    procedure PoseLeg(Index:Integer;const A,B:TVector3);
    function PointOutside(Index:Integer):TVector3;
    function LegCorrection(Index:Integer;const P,Outside:TVector3;out D:TVector3):Boolean;
    procedure Sew;
    procedure Step(const Gravity,Wind,Acceleration:TVector3);
  public
    constructor Create(Scale,LengthY,Density,Slack:Single;Vent:Boolean);
    procedure Reset;
    function RestPoint(Index:Integer):TVector3;
    procedure SetPose(const Targets:THemPositions);
    procedure SetMetric(const Points:THemPositions);
    procedure SetBody(Row:Integer;const Frame:TMatrix4;Build:Single);
    procedure SetHip(const Frame:TMatrix4;const Centre,Radii:TVector3);
    procedure SetLeg(Index:Integer;const A,B:TVector3;Radius:Single;TipRadius:Single=-1);
    procedure SetLegSection(Index:Integer;const A,B:TVector3;Width,Depth,TipWidth,TipDepth:Single;BackOffset:Single=0;InnerWidth:Single=-1;TipInnerWidth:Single=-1);
    procedure Advance(Dt:Single;const Frame:TMatrix4;
      const Gravity,Wind,Travel:TVector3;Speed:Single);
    procedure Offsets(out Values:THemOffsets);
    function MaxDisplacement:Single;
    function PointDisplacement(Index:Integer):Single;
    function MaxSpeed:Single;
    function MaxStretch:Single;
    procedure StretchPeak(out EdgeA,EdgeB:Integer;out SignedError:Single);
    function TorsoDisplacement:Single;
    property SimulatedTime:Double read FTime;
  end;
implementation
uses Math, AvatarGarmentPattern;
const StepTime=1/120;
function Limited(const P:TVector3;Limit:Single):TVector3;
var L:Single;
begin L:=P.Length;Result:=P;if L>Limit then Result:=P*(Limit/L) end;
function Smooth(A,B,X:Single):Single;
begin Result:=EnsureRange((X-A)/(B-A),0.0,1.0);Result:=Result*Result*(3-2*Result) end;

constructor TAvatarHemDynamics.Create(Scale,LengthY,Density,Slack:Single;Vent:Boolean);
var Row,Side,Column,K,A:Integer;T,Y,Angle,Front,Back,RX,RZ,CZ,E:Single;
begin
  inherited Create;FScale:=Scale;FLength:=LengthY*Scale;
  FDensity:=EnsureRange(Density,120,600);FVent:=Vent;FBuild:=1;
  for Row:=0 to HemRows-1 do for Side:=0 to 1 do for Column:=0 to HemColumns-1 do begin
    T:=Max(0,(Row-HemTorsoRows)/HemSkirtRows);
    Y:=1.43-0.33*Row/HemTorsoRows;
    if Row>=HemTorsoRows then Y:=1.10-LengthY*T;
    OuterwearOpening(T,Vent,Front,Back);
    Angle:=Front+(Pi-Front-Back)*Column/(HemColumns-1);if Side=1 then Angle:=-Angle;
    OuterwearSection(Slack,Y,RX,RZ,CZ);
    E:=OuterwearSectionExponent(Y);
    RX:=RX*Scale;RZ:=RZ*Scale;
    K:=Row*HemRing+Side*HemColumns+Column;
    FRest[K]:=Vector3(RX*Sign(Sin(Angle))*Power(Abs(Sin(Angle)),E),Y*Scale,
      CZ*Scale+RZ*Sign(Cos(Angle))*Power(Abs(Cos(Angle)),E));
    FRestOutside[K]:=Vector3(Sign(Sin(Angle))*Power(Abs(Sin(Angle)),2-E)/RX,0,
      Sign(Cos(Angle))*Power(Abs(Cos(Angle)),2-E)/RZ).Normalize;
  end;
  for Row:=0 to HemRows-1 do for Side:=0 to 1 do for Column:=0 to HemColumns-1 do begin
    K:=Row*HemRing+Side*HemColumns+Column;
    if Column<HemColumns-1 then Edge(K,K+1,1e-7);
    if Column<HemColumns-2 then Edge(K,K+2,0.014*(280/FDensity));
    if Row<HemRows-1 then begin
      A:=K+HemRing;Edge(K,A,1e-8);
      if Column<HemColumns-1 then begin Edge(K,A+1,0.000012);Edge(K+1,A,0.000012) end;
    end;
    if Row<HemRows-2 then Edge(K,K+2*HemRing,0.012*(280/FDensity));
  end;
  FTarget:=FRest;FLastTarget:=FRest;FStepTarget:=FRest;FMetric:=FRest;
  for Row:=0 to HemTorsoRows do SetBody(Row,TMatrix4.Identity,1);
  Reset;
end;
procedure TAvatarHemDynamics.Edge(A,B:Integer;Compliance:Single);
var I:Integer;
begin
  I:=Length(FEdges);SetLength(FEdges,I+1);FEdges[I].A:=A;FEdges[I].B:=B;
  FEdges[I].Length:=(FRest[A]-FRest[B]).Length;FEdges[I].Compliance:=Compliance;
end;
procedure TAvatarHemDynamics.Reset;
begin
  FPosition:=FTarget;FPrevious:=FTarget;FLastTarget:=FTarget;
  FStepTarget:=FTarget;FillChar(FVelocity,SizeOf(FVelocity),0);
  FillChar(FLastLegValid,SizeOf(FLastLegValid),0);
  FValid:=False;FRemainder:=0;
end;
function TAvatarHemDynamics.RestPoint(Index:Integer):TVector3;
begin Result:=FRest[Index] end;
procedure TAvatarHemDynamics.SetPose(const Targets:THemPositions);
begin FTarget:=Targets end;
procedure TAvatarHemDynamics.SetMetric(const Points:THemPositions);
var I:Integer;Changed:Boolean;
begin
  Changed:=False;
  for I:=0 to HemPoints-1 do if(Points[I]-FMetric[I]).LengthSqr>1e-8 then begin Changed:=True;Break end;
  if not Changed then Exit;
  FMetric:=Points;
  for I:=0 to High(FEdges)do FEdges[I].Length:=(Points[FEdges[I].A]-Points[FEdges[I].B]).Length;
  Reset;
end;
procedure TAvatarHemDynamics.SetBody(Row:Integer;const Frame:TMatrix4;Build:Single);
var Y,RX,RZ,CZ:Single;
begin
  if(Row<0)or(Row>HemTorsoRows)then Exit;
  FBuild:=Max(0.8,Build);Y:=1.43-0.33*Row/HemTorsoRows;
  OuterwearBodySection(Y,RX,RZ,CZ);
  FBodyCentre[Row]:=Frame.MultPoint(Vector3(0,Y*FScale,CZ*FScale));
  FBodyX[Row]:=Frame.MultDirection(Vector3(1,0,0)).Normalize;
  FBodyY[Row]:=Frame.MultDirection(Vector3(0,1,0)).Normalize;
  FBodyZ[Row]:=Frame.MultDirection(Vector3(0,0,1)).Normalize;
  FBodyRX[Row]:=RX*FScale*FBuild;
  FBodyRZ[Row]:=RZ*FScale*FBuild;
end;

procedure TAvatarHemDynamics.ProjectBody(var P:TVector3);
var Row:Integer;RX,RZ,D,L:Single;X,Z,Q,Delta:TVector3;
begin
  { Overlapping short elliptical sections follow the torso. Contact is a
    unilateral support; it never attracts the cloth to the body. }
  for Row:=0 to HemTorsoRows do begin
    X:=FBodyX[Row];Z:=FBodyZ[Row];
    Delta:=P-FBodyCentre[Row];Q:=Vector3(TVector3.DotProduct(Delta,X),
      TVector3.DotProduct(Delta,FBodyY[Row]),TVector3.DotProduct(Delta,Z));
    if Abs(Q.Y)>0.070*FScale then Continue;
    RX:=FBodyRX[Row];RZ:=FBodyRZ[Row];
    D:=Sqrt(Sqr(Q.X/RX)+Sqr(Q.Z/RZ));
    if(D<1)and(D>1e-6)then begin
      L:=Min(1/D-1,0.025*FScale/Max(Sqrt(Sqr(Q.X)+Sqr(Q.Z)),1e-6));
      P:=P+(X*Q.X+Z*Q.Z)*L;
    end;
  end;
  { The pelvis used to exist only in the dense render contact. Let the
    cloth constraints distribute this contact across a panel first, so
    the shader does not inflate isolated vertices into a horizontal roll. }
  if FHipValid then begin
    Q:=FHipInverse.MultPoint(P)-FHipCentre;
    { A pelvis is broader across its front/back corners than an ellipsoid.
      Match the rounded trouser envelope instead of adding radius to every
      direction, which would lift the complete hem away from the body. }
    D:=Power(Power(Abs(Q.X/FHipRadii.X),OuterwearHipPower)+
      Power(Abs(Q.Y/FHipRadii.Y),OuterwearHipPower)+
      Power(Abs(Q.Z/FHipRadii.Z),OuterwearHipPower),1/OuterwearHipPower);
    if(D<1)and(D>1e-6)then
      P:=P+Limited(FHipFrame.MultDirection(Q*(1/D-1)),0.025*FScale);
  end;
end;

procedure TAvatarHemDynamics.SetHip(const Frame:TMatrix4;const Centre,Radii:TVector3);
begin
  FHipFrame:=Frame;FHipCentre:=Centre;FHipRadii:=Radii;
  FHipValid:=(Min(Radii.X,Min(Radii.Y,Radii.Z))>1e-5)and Frame.TryInverse(FHipInverse);
end;

procedure TAvatarHemDynamics.Sew;
var Row,A,B:Integer;Joined:TVector3;T:Single;
begin
  for Row:=1 to HemRows-1 do begin
    T:=Max(0,(Row-HemTorsoRows)/HemSkirtRows);
    if not FVent or(T<=0.66)then begin
      A:=Row*HemRing+HemColumns-1;B:=Row*HemRing+HemRing-1;
      Joined:=(FPosition[A]+FPosition[B])*0.5;FPosition[A]:=Joined;FPosition[B]:=Joined;
    end;
    if not FVent or(Row<=HemTorsoRows)then begin
      A:=Row*HemRing;B:=A+HemColumns;
      Joined:=(FPosition[A]+FPosition[B])*0.5;FPosition[A]:=Joined;FPosition[B]:=Joined;
    end;
  end;
end;

function TAvatarHemDynamics.PointOutside(Index:Integer):TVector3;
var Row:Integer;Centre:TVector3;
begin
  Row:=Index div HemRing;
  Centre:=(FStepTarget[Row*HemRing]+FStepTarget[Row*HemRing+HemColumns-1])*0.5;
  Result:=FStepTarget[Index]-Centre;
  if Result.LengthSqr>1e-8 then Result:=Result.Normalize;
end;
procedure TAvatarHemDynamics.ProjectLegs(Index:Integer;FinalPass:Boolean);
var I:Integer;N,D:TVector3;Limit:Single;
begin
  N:=FStepOutside[Index];
  if N.LengthSqr<1e-8 then Exit;
  Limit:=0.003*FScale;
  if FVent and(Index>=HemTorsoRows*HemRing)then Limit:=0.025*FScale;
  if FinalPass then Limit:=Min(Limit,0.008*FScale);
  for I:=0 to 3 do if LegCorrection(I,FPosition[Index],N,D)then begin
    FPosition[Index]:=FPosition[Index]+Limited(D,Limit);
    FTouched[Index]:=True;
  end;
end;
procedure TAvatarHemDynamics.SetLeg(Index:Integer;const A,B:TVector3;Radius,TipRadius:Single);
begin
  if TipRadius<0 then TipRadius:=Radius*0.7;
  SetLegSection(Index,A,B,Radius,Radius,TipRadius,TipRadius);
end;
procedure TAvatarHemDynamics.SetLegSection(Index:Integer;const A,B:TVector3;Width,Depth,TipWidth,TipDepth,BackOffset,InnerWidth,TipInnerWidth:Single);
begin
  if(Index<0)or(Index>3)then Exit;
  FLegA[Index]:=A;FLegB[Index]:=B;
  FLegRadius[Index]:=Max(0,Depth);FLegTipRadius[Index]:=Max(0,TipDepth);
  FLegWidth[Index]:=Max(0,Width);FLegTipWidth[Index]:=Max(0,TipWidth);
  if InnerWidth<0 then InnerWidth:=Width;
  if TipInnerWidth<0 then TipInnerWidth:=TipWidth;
  FLegInnerWidth[Index]:=Max(0,InnerWidth);FLegTipInnerWidth[Index]:=Max(0,TipInnerWidth);
  PoseLeg(Index,A,B);
  FLegA[Index]:=A+FLegZ[Index]*BackOffset;FLegB[Index]:=B+FLegZ[Index]*BackOffset;
end;
procedure TAvatarHemDynamics.PoseLeg(Index:Integer;const A,B:TVector3);
var Axis,X:TVector3;L:Single;
begin
  FLegA[Index]:=A;FLegB[Index]:=B;Axis:=B-A;L:=Axis.LengthSqr;
  if L<1e-8 then begin FLegRadius[Index]:=0;Exit end;
  FLegAxis[Index]:=Axis;FLegInvLengthSqr[Index]:=1/L;
  Axis:=Axis/Sqrt(L);FLegY[Index]:=Axis;
  X:=Vector3(1,0,0)-Axis*Axis.X;
  if X.LengthSqr<1e-6 then X:=Vector3(0,0,1)-Axis*Axis.Z;
  FLegX[Index]:=X.Normalize;FLegZ[Index]:=TVector3.CrossProduct(FLegX[Index],Axis);
end;
function TAvatarHemDynamics.LegCorrection(Index:Integer;const P,Outside:TVector3;out D:TVector3):Boolean;
var T,RX,RY,RZ,RI,L,AA,BB,CC,Travel,Lo,Hi,Mid:Single;Q,Local,Dir,Ray,Probe:TVector3;K:Integer;
  function SectionDistance(const V:TVector3):Single;
  var X,Y,Z:Single;
  begin
    X:=TVector3.DotProduct(V,FLegX[Index]);
    Y:=TVector3.DotProduct(V,FLegY[Index])/RY;
    Z:=TVector3.DotProduct(V,FLegZ[Index])/RZ;
    if(X*(1-2*(Index mod 2))>0)and(RI>RX+0.0001)then
      Result:=Sqrt(Sqrt(Sqr(Sqr(X/RI))+Sqr(Sqr(Z)))+Sqr(Y))
    else Result:=Sqrt(Sqr(X/RX)+Sqr(Y)+Sqr(Z));
  end;
begin
  Result:=False;D:=TVector3.Zero;if FLegRadius[Index]<=0 then Exit;
  Q:=P-FLegA[Index];
  T:=EnsureRange(TVector3.DotProduct(Q,FLegAxis[Index])*FLegInvLengthSqr[Index],0.02,0.99);
  Q:=Q-FLegAxis[Index]*T;
  RX:=Max(0.001,FLegWidth[Index]*(1-T)+FLegTipWidth[Index]*T);
  RI:=Max(0.001,FLegInnerWidth[Index]*(1-T)+FLegTipInnerWidth[Index]*T);
  RZ:=Max(0.001,FLegRadius[Index]*(1-T)+FLegTipRadius[Index]*T);RY:=Max(RX,RZ);
  { The hip collider already covers the pelvis. A spherical thigh cap
    extends its full front/back radius above the hip joint and falsely
    pushes the waist out, even above the top of the trousers. }
  if(Index<2)and(TVector3.DotProduct(Q,FLegY[Index])<0)then RY:=Min(RY,0.035*FScale);
  Local:=Vector3(TVector3.DotProduct(Q,FLegX[Index])/RX,
    TVector3.DotProduct(Q,FLegY[Index])/RY,TVector3.DotProduct(Q,FLegZ[Index])/RZ);
  CC:=Sqr(SectionDistance(Q))-1;if CC>=0 then Exit;
  L:=Q.Length;
  if(Outside.LengthSqr>0.5)and(TVector3.DotProduct(Q,Outside)<Min(RX,RZ)*0.2)then Dir:=Outside
  else if L>1e-6 then Dir:=Q/L else Dir:=FLegX[Index];
  if RI>RX+0.0001 then begin
    { The crotch bridges the two legs; its medial section has a broader
      corner than the outer thigh. Solve the ray against that same fitted
      section, including rays crossing from one half into the other. }
    Lo:=0;Hi:=3*Max(RY,Max(RZ,Max(RX,RI)));
    for K:=1 to 10 do begin
      Mid:=(Lo+Hi)*0.5;Probe:=Q+Dir*Mid;
      if SectionDistance(Probe)<1 then Lo:=Mid else Hi:=Mid;
    end;
    D:=Dir*Hi;Exit(True);
  end;
  { The same anisotropic section as the render contact. A round capsule
    with the larger depth pushed both sides of the hem into a bell shape. }
  Ray:=Vector3(TVector3.DotProduct(Dir,FLegX[Index])/RX,
    TVector3.DotProduct(Dir,FLegY[Index])/RY,TVector3.DotProduct(Dir,FLegZ[Index])/RZ);
  AA:=Ray.LengthSqr;BB:=TVector3.DotProduct(Local,Ray);
  Travel:=(-BB+Sqrt(Max(0,Sqr(BB)-AA*CC)))/Max(1e-8,AA);
  D:=Dir*Max(0,Travel);Result:=True;
end;
procedure TAvatarHemDynamics.ProjectLegEdge(A,B:Integer);
var I,K:Integer;U,Denom:Single;P,N,D,NA,NB:TVector3;
begin
  { Thighs and calves can cross a panel between cage particles. Endpoints
    are already handled by ProjectLegs; sample only the edge interior. }
  NA:=FStepOutside[A];NB:=FStepOutside[B];
  for K:=1 to 3 do begin
    U:=K/4;P:=FPosition[A]*(1-U)+FPosition[B]*U;
    N:=(NA*(1-U)+NB*U).Normalize;
    for I:=0 to 3 do if LegCorrection(I,P,N,D)then begin
      Denom:=Sqr(1-U)+Sqr(U);
      D:=Limited(D,0.025*FScale)/Denom;
      FPosition[A]:=FPosition[A]+D*(1-U);
      FPosition[B]:=FPosition[B]+D*U;
      FTouched[A]:=True;FTouched[B]:=True;
      P:=FPosition[A]*(1-U)+FPosition[B]*U;
    end;
  end;
end;
procedure TAvatarHemDynamics.Step(const Gravity,Wind,Acceleration:TVector3);
var Old:THemPositions;I,J,A,B,Row,Side:Integer;
  Alpha,MassA,MassB,L,DL,Damping,Air,Limit:Single;
  D,Normal,Force:TVector3;
begin
  Old:=FPosition;FPrevious:=FPosition;
  for I:=HemRing to HemPoints-1 do FStepOutside[I]:=PointOutside(I);
  FillChar(FTouched,SizeOf(FTouched),0);
  for I:=0 to High(FEdges)do FEdges[I].Lambda:=0;
  for I:=0 to HemRing-1 do FPosition[I]:=FStepTarget[I];
  for I:=HemRing to HemPoints-1 do begin
    Normal:=FRestOutside[I];
    Air:=0.075*(260/FDensity)*Abs(TVector3.DotProduct(Wind,Normal));
    Force:=Gravity-Acceleration+Limited(Wind*Air,9);
    for Side:=0 to 3 do if LegCorrection(Side,FPosition[I],TVector3.Zero,D)then
      Force:=Force+Limited(D*180,18);
    FVelocity[I]:=FVelocity[I]+Force*StepTime;
    FPosition[I]:=FPosition[I]+FVelocity[I]*StepTime;
  end;
  for J:=0 to 5+2*Ord(FVent)do begin
    for I:=HemRing to HemPoints-1 do begin ProjectBody(FPosition[I]);ProjectLegs(I)end;
    if FVent then for I:=0 to High(FEdges)do
      if(FEdges[I].Compliance<=1e-7)and(FEdges[I].A>=HemTorsoRows*HemRing)and
        (FEdges[I].B>=HemTorsoRows*HemRing)then ProjectLegEdge(FEdges[I].A,FEdges[I].B);
    for I:=0 to High(FEdges)do begin
      A:=FEdges[I].A;B:=FEdges[I].B;
      MassA:=Ord(A>=HemRing)*(350/FDensity);MassB:=Ord(B>=HemRing)*(350/FDensity);
      if MassA+MassB=0 then Continue;
      D:=FPosition[A]-FPosition[B];L:=D.Length;if L<1e-7 then Continue;
      Alpha:=FEdges[I].Compliance/Sqr(StepTime);
      DL:=(-(L-FEdges[I].Length)-Alpha*FEdges[I].Lambda)/(MassA+MassB+Alpha);
      FEdges[I].Lambda:=FEdges[I].Lambda+DL;D:=D*(DL/L);
      FPosition[A]:=FPosition[A]+D*MassA;FPosition[B]:=FPosition[B]-D*MassB;
    end;
    Sew;
    for I:=HemRing to HemPoints-1 do begin
      Row:=I div HemRing;
      { Maximum travel only, not a spring back to an inflated rest shape.
        Cloth is allowed to sag, buckle and retain contact-induced folds.
        A free panel tilted by 60 degrees needs its full hanging length
        to rotate down. Structural edges still constrain the fabric length. }
      Limit:=FScale*(0.014+0.010*Min(Row,HemTorsoRows));
      if Row>HemTorsoRows then Limit:=Limit+FLength*(Row-HemTorsoRows)/HemSkirtRows;
      D:=Limited(FPosition[I]-FStepTarget[I],Limit);FPosition[I]:=FStepTarget[I]+D;
    end;
  end;
  { Distance constraints may move a contact point a few millimetres back
    into the pelvis. Finish on the body surface, as the dense GPU mesh
    does, so the cage does not leave that correction to the renderer. }
  for I:=HemRing to HemPoints-1 do begin
    ProjectBody(FPosition[I]);
    if FVent then ProjectLegs(I,True);
  end;
  Sew;
  Damping:=Exp(-5.2*StepTime)/StepTime;
  for I:=HemRing to HemPoints-1 do begin
    FVelocity[I]:=Limited((FPosition[I]-Old[I])*Damping,4);
    if FTouched[I]then FVelocity[I]:=FVelocity[I]*0.72;
  end;
  FTime:=FTime+StepTime;
end;
procedure TAvatarHemDynamics.Advance(Dt:Single;const Frame:TMatrix4;
  const Gravity,Wind,Travel:TVector3;Speed:Single);
var Inverse,Change:TMatrix4;G,W,Accel:TVector3;I,Steps,Count:Integer;Blend:Single;
  GoalLegA,GoalLegB:array[0..3]of TVector3;
begin
  if Dt<=0 then Exit;
  if Dt>0.25 then begin Reset;Dt:=StepTime end;
  if not Frame.TryInverse(Inverse)then Exit;
  if not FValid then begin FFrame:=Frame;FLastSpeed:=Speed;FPosition:=FTarget;FPrevious:=FTarget;FLastTarget:=FTarget;FValid:=True end;
  Change:=Inverse*FFrame;
  if(Change.MultPoint(Vector3(0,1.10*FScale,0))-Vector3(0,1.10*FScale,0)).Length>0.45 then begin
    Reset;FValid:=True;FLastSpeed:=Speed;
  end else for I:=0 to HemPoints-1 do begin
    FPosition[I]:=Change.MultPoint(FPosition[I]);FPrevious[I]:=Change.MultPoint(FPrevious[I]);
    FVelocity[I]:=Change.MultDirection(FVelocity[I]);FLastTarget[I]:=Change.MultPoint(FLastTarget[I]);
  end;
  FFrame:=Frame;G:=Inverse.MultDirection(Gravity);W:=Inverse.MultDirection(Wind);
  { Cloth runs at 120 Hz, so its colliders must travel through the same
    substeps instead of jumping to the final render-frame leg pose. }
  GoalLegA:=FLegA;GoalLegB:=FLegB;
  for I:=0 to 3 do begin
    if FLastLegValid[I]then begin
      FLastLegA[I]:=Change.MultPoint(FLastLegA[I]);
      FLastLegB[I]:=Change.MultPoint(FLastLegB[I]);
    end else begin FLastLegA[I]:=GoalLegA[I];FLastLegB[I]:=GoalLegB[I] end;
    FLastLegValid[I]:=FLegRadius[I]>0;
  end;
  Accel:=Inverse.MultDirection(Travel*EnsureRange((Speed-FLastSpeed)/Max(Dt,0.001),-10.0,10.0));
  FLastSpeed:=Speed;FRemainder:=FRemainder+Dt;Steps:=0;Count:=Min(30,Trunc(FRemainder/StepTime));
  while(FRemainder>=StepTime)and(Steps<30)do begin
    Blend:=(Steps+1)/Max(1,Count);
    for I:=0 to HemPoints-1 do FStepTarget[I]:=FLastTarget[I]*(1-Blend)+FTarget[I]*Blend;
    for I:=0 to 3 do if FLegRadius[I]>0 then
      PoseLeg(I,FLastLegA[I]*(1-Blend)+GoalLegA[I]*Blend,
        FLastLegB[I]*(1-Blend)+GoalLegB[I]*Blend);
    Step(G,W,Accel);FRemainder:=FRemainder-StepTime;Inc(Steps);
  end;
  if Steps>0 then begin FLastTarget:=FTarget;FLastLegA:=GoalLegA;FLastLegB:=GoalLegB end;
  for I:=0 to 3 do if FLegRadius[I]>0 then PoseLeg(I,GoalLegA[I],GoalLegB[I]);
end;
procedure TAvatarHemDynamics.Offsets(out Values:THemOffsets);
var I:Integer;T:Single;
begin
  T:=EnsureRange(FRemainder/StepTime,0,1);
  for I:=0 to HemMovingPoints-1 do
    Values[I]:=FPrevious[I+HemRing]*(1-T)+FPosition[I+HemRing]*T-FTarget[I+HemRing];
end;
function TAvatarHemDynamics.MaxDisplacement:Single;
var I:Integer;
begin Result:=0;for I:=HemRing to HemPoints-1 do Result:=Max(Result,(FPosition[I]-FTarget[I]).Length) end;
function TAvatarHemDynamics.PointDisplacement(Index:Integer):Single;
begin
  Result:=0;if(Index>=0)and(Index<HemPoints)then Result:=(FPosition[Index]-FTarget[Index]).Length;
end;
function TAvatarHemDynamics.TorsoDisplacement:Single;
var I:Integer;
begin Result:=0;for I:=HemRing to HemTorsoRows*HemRing-1 do Result:=Max(Result,(FPosition[I]-FTarget[I]).Length) end;
function TAvatarHemDynamics.MaxSpeed:Single;
var I:Integer;
begin Result:=0;for I:=HemRing to HemPoints-1 do Result:=Max(Result,FVelocity[I].Length) end;
function TAvatarHemDynamics.MaxStretch:Single;
var A,B:Integer;Error:Single;
begin
  StretchPeak(A,B,Error);Result:=Abs(Error);
end;
procedure TAvatarHemDynamics.StretchPeak(out EdgeA,EdgeB:Integer;out SignedError:Single);
var I:Integer;Error:Single;
begin
  EdgeA:=-1;EdgeB:=-1;SignedError:=0;
  for I:=0 to High(FEdges)do if FEdges[I].Compliance<=1e-7 then begin
    Error:=(FPosition[FEdges[I].A]-FPosition[FEdges[I].B]).Length-FEdges[I].Length;
    if Abs(Error)>Abs(SignedError)then begin
      SignedError:=Error;EdgeA:=FEdges[I].A;EdgeB:=FEdges[I].B;
    end;
  end;
end;
end.
