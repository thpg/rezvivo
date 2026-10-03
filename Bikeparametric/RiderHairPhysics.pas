unit RiderHairPhysics;
{$mode objfpc}{$H+}
interface
uses CastleVectors, RiderHairData;
type
  THairPoints = array[0..HairPointCount-1]of TVector3;
  THairMotionState = record
    Valid:Boolean;
    Time, Remainder, PendingTime:Double;
    Position,Previous,Velocity:THairPoints;
    Frame:TMatrix4;
    LastSpeed:Single;
    StepSeconds:Single;
    DetailLevel:Integer;
    ShaderDetail:Single;
  end;
  TRiderHairPhysics = class
  private
    FGuides:THairGuides;
    FRest:THairPoints;
    FState:THairMotionState;
    FHelmet:Boolean;
    FLengths,FCompliance:array[0..HairPointCount-1]of Single;
    FPinned:array[0..HairPointCount-1]of Boolean;
    FProxy:array[0..2,0..HairGuideCount-1]of Integer;
    FTorsoA,FTorsoB:TVector3;
    FTorsoRadius:Single;
    procedure CollideTorso(var P:TVector3);
    procedure Step(const Dt:Single;const Gravity,Wind,Acceleration:TVector3);
  public
    procedure SetGuides(const Guides:THairGuides;Helmet:Boolean);
    procedure SetTorso(const A,B:TVector3;Radius:Single);
    procedure Reset;
    procedure SetDetail(Level:Integer);
    procedure Advance(Dt:Single;const Frame:TMatrix4;const Gravity,Wind,Travel:TVector3;Speed:Single);
    function RenderPoint(Index:Integer):TVector3;
    procedure Restore(const Value:THairMotionState);
    property State:THairMotionState read FState;
    function MaxDisplacement:Single;
    function MaxLengthError:Single;
    function ActiveGuideCount:Integer;
  end;
implementation
uses Math;
function Limited(const V:TVector3;Limit:Single):TVector3;
begin
  Result:=V;
  if V.LengthSqr>Sqr(Limit)then Result:=V*(Limit/Sqrt(V.LengthSqr));
end;
procedure TRiderHairPhysics.SetGuides(const Guides:THairGuides;Helmet:Boolean);
var I,J,K,L,G,Best:Integer;FullLength,T,Score,BestScore:Single;
begin
  FGuides:=Guides;FHelmet:=Helmet;
  for I:=0 to HairGuideCount-1 do for J:=0 to HairGuidePoints-1 do
    if Helmet then FRest[I*HairGuidePoints+J]:=Guides[I].Helmet[J]
    else FRest[I*HairGuidePoints+J]:=Guides[I].Rest[J];
  for I:=0 to HairGuideCount-1 do begin
    FullLength:=0;
    for J:=1 to HairGuidePoints-1 do begin
      K:=I*HairGuidePoints+J;FLengths[K]:=(FRest[K]-FRest[K-1]).Length;
      FullLength:=FullLength+FLengths[K];
    end;
    for J:=0 to HairGuidePoints-1 do begin
      K:=I*HairGuidePoints+J;FPinned[K]:=J<Integer(Guides[I].Pinned);T:=J/(HairGuidePoints-1);
      FCompliance[K]:=0.0012*Sqr(FullLength/0.08)*Sqr(T)*(1.05-Guides[I].Stiffness);
      if Helmet and(FRest[K].Y>0.045)then FCompliance[K]:=FCompliance[K]*0.08;
    end;
  end;
  { Far hair follows a representative set of guides. Select by both root and
    tip, and keep tied tails separate from scalp locks. Rest offsets preserve
    the individual curls instead of collapsing them onto the selected guide. }
  for L:=0 to 2 do for I:=0 to HairGuideCount-1 do begin
    Best:=I;BestScore:=MaxSingle;
    if(L=0)or((L=1)and(I mod 3<>2))or((L=2)and(I mod 3=0))then begin
      FProxy[L,I]:=I;Continue;
    end;
    for G:=0 to HairGuideCount-1 do
      if(((L=1)and(G mod 3<>2))or((L=2)and(G mod 3=0)))and
        (FGuides[G].Pinned=FGuides[I].Pinned)then begin
        Score:=(FRest[G*HairGuidePoints]-FRest[I*HairGuidePoints]).LengthSqr+
          0.1*(FRest[(G+1)*HairGuidePoints-1]-FRest[(I+1)*HairGuidePoints-1]).LengthSqr;
        if Score<BestScore then begin BestScore:=Score;Best:=G end;
      end;
    FProxy[L,I]:=Best;
  end;
  Reset;
end;
procedure TRiderHairPhysics.Reset;
var Interval:Single;Level:Integer;
begin
  Interval:=FState.StepSeconds;if Interval<=0 then Interval:=1/120;
  Level:=FState.DetailLevel;
  FState:=Default(THairMotionState);FState.Position:=FRest;
  FState.Previous:=FRest;FState.StepSeconds:=Interval;FState.DetailLevel:=Level;
end;
procedure TRiderHairPhysics.SetDetail(Level:Integer);
var Interval:Single;
begin
  FState.DetailLevel:=EnsureRange(Level,0,2);
  case Level of 0:Interval:=1/120;1:Interval:=1/60;else Interval:=1/30 end;
  if Abs(Interval-FState.StepSeconds)<1e-8 then Exit;
  FState.StepSeconds:=Interval;FState.Remainder:=0;FState.Previous:=FState.Position;
end;
procedure TRiderHairPhysics.SetTorso(const A,B:TVector3;Radius:Single);
begin FTorsoA:=A;FTorsoB:=B;FTorsoRadius:=Radius end;
procedure TRiderHairPhysics.CollideTorso(var P:TVector3);
var Axis,Center,D:TVector3;T,L:Single;
begin
  if FTorsoRadius<=0 then Exit;
  Axis:=FTorsoB-FTorsoA;
  T:=EnsureRange(TVector3.DotProduct(P-FTorsoA,Axis)/Max(Axis.LengthSqr,1e-8),0.0,1.0);
  Center:=FTorsoA+Axis*T;D:=P-Center;L:=D.Length;
  if (L<FTorsoRadius)and(L>1e-6)then P:=Center+D*(FTorsoRadius/L);
end;
procedure TRiderHairPhysics.Restore(const Value:THairMotionState);
begin
  FState:=Value;
  { Replay carries four render LODs; the last two share the coarse solver. }
  FState.DetailLevel:=EnsureRange(FState.DetailLevel,0,2);
end;

procedure TRiderHairPhysics.Step(const Dt:Single;const Gravity,Wind,Acceleration:TVector3);
var Old:THairPoints; ShapeLambda:THairPoints;
  Lambda:array[0..HairPointCount-1]of Single;
  I,J,K,A,B,Iteration,Iterations,Proxy:Integer;W0,W1,L,RestL,DL,Alpha,WindLength,Damping:Single;
  D,V,Q,Correction,Gust:TVector3;
  procedure Ellipsoid(var P:TVector3;const Center,Radii:TVector3);
  var E:TVector3;S:Single;
  begin
    E:=P-Center;E:=Vector3(E.X/Radii.X,E.Y/Radii.Y,E.Z/Radii.Z);
    S:=E.LengthSqr;
    if(S>1e-8)and(S<1)then begin
      E:=E/Sqrt(S);P:=Center+Vector3(E.X*Radii.X,E.Y*Radii.Y,E.Z*Radii.Z);
    end;
  end;
begin
  Old:=FState.Position;FillChar(Lambda,SizeOf(Lambda),0);FillChar(ShapeLambda,SizeOf(ShapeLambda),0);
  FState.Previous:=Old;
  WindLength:=Wind.Length;
  for I:=0 to HairGuideCount-1 do begin
    if FProxy[FState.DetailLevel,I]<>I then Continue;
    Gust:=Vector3(Sin(FState.Time*3.1+I*0.72),Sin(FState.Time*2.3+I*0.39)*0.25,
      Sin(FState.Time*1.7+I*0.44))*(0.18+0.035*WindLength);
    for J:=0 to HairGuidePoints-1 do begin
    K:=I*HairGuidePoints+J;
    if J<Integer(FGuides[I].Pinned)then begin FState.Position[K]:=FRest[K];Continue end;
    V:=Wind+Gust-FState.Velocity[K];
    V:=Gravity-Acceleration+Limited(V*V.Length*0.12,45);
    FState.Position[K]:=FState.Position[K]+FState.Velocity[K]*Dt+V*Sqr(Dt);
    end;
  end;
  { Larger distant time steps need extra constraint passes, especially for a
    tail touching the neck. Nine passes at 30 Hz still cost less than five at
    120 Hz, without stretching the individual segments during an LOD change. }
  Iterations:=5;if Dt>0.025 then Iterations:=9;
  for Iteration:=0 to Iterations-1 do
    for I:=0 to HairGuideCount-1 do begin
      if FProxy[FState.DetailLevel,I]<>I then Continue;
      A:=I*HairGuidePoints;
      for J:=Integer(FGuides[I].Pinned)to HairGuidePoints-1 do begin
        K:=A+J;
        Alpha:=Max(FCompliance[K],1e-7)/Sqr(Dt);
        Correction:=(-(FState.Position[K]-FRest[K])-ShapeLambda[K]*Alpha)/(1+Alpha);
        ShapeLambda[K]:=ShapeLambda[K]+Correction;
        FState.Position[K]:=FState.Position[K]+Correction;
      end;
      for J:=1 to HairGuidePoints-1 do begin
        K:=A+J;B:=K-1;D:=FState.Position[K]-FState.Position[B];L:=D.Length;
        if L<1e-8 then Continue;
        W0:=Ord(J>=Integer(FGuides[I].Pinned));W1:=Ord(J-1>=Integer(FGuides[I].Pinned));
        if W0+W1=0 then Continue;
        RestL:=FLengths[K];Alpha:=1e-9/Sqr(Dt);
        DL:=(-(L-RestL)-Alpha*Lambda[K])/(W0+W1+Alpha);Lambda[K]:=Lambda[K]+DL;
        D:=D*(DL/L);
        FState.Position[K]:=FState.Position[K]+D*W0;
        FState.Position[B]:=FState.Position[B]-D*W1;
      end;
      for J:=Integer(FGuides[I].Pinned)to HairGuidePoints-1 do begin
        K:=A+J;Q:=FState.Position[K];
        { The common anatomical cranial vault. The scanned head's old volume
          extended 3 cm behind the new occiput and lifted even short locks. }
        Ellipsoid(Q,Vector3(0,0.068,0.040),Vector3(0.067,0.094,0.093));
        Ellipsoid(Q,Vector3(0,-0.055,-0.010),Vector3(0.035,0.060,0.033));
        { Conservative shoulder envelope; roots on the scalp stay untouched. }
        if FRest[K].Y< -0.12 then
          Ellipsoid(Q,Vector3(0,-0.285,0.035),Vector3(0.20,0.065,0.080));
        CollideTorso(Q);
        FState.Position[K]:=Q;
      end;
    end;
  for I:=0 to HairGuideCount-1 do begin
    Proxy:=FProxy[FState.DetailLevel,I];if Proxy=I then Continue;
    for J:=0 to HairGuidePoints-1 do begin
      K:=I*HairGuidePoints+J;A:=Proxy*HairGuidePoints+J;
      if FPinned[K]then FState.Position[K]:=FRest[K]
      else begin
        Q:=FRest[K]+FState.Position[A]-FRest[A];
        Ellipsoid(Q,Vector3(0,0.068,0.040),Vector3(0.067,0.094,0.093));
        Ellipsoid(Q,Vector3(0,-0.055,-0.010),Vector3(0.035,0.060,0.033));
        if FRest[K].Y< -0.12 then
          Ellipsoid(Q,Vector3(0,-0.285,0.035),Vector3(0.20,0.065,0.080));
        CollideTorso(Q);
        D:=Q-FState.Position[K-1];L:=D.Length;
        if L>1e-8 then Q:=FState.Position[K-1]+D*(FLengths[K]/L);
        FState.Position[K]:=Q;
      end;
    end;
  end;
  Damping:=Exp(-7*Dt)/Dt;
  for K:=0 to HairPointCount-1 do
    FState.Velocity[K]:=Limited((FState.Position[K]-Old[K])*Damping,4);
  FState.Time:=FState.Time+Dt;
end;

procedure TRiderHairPhysics.Advance(Dt:Single;const Frame:TMatrix4;const Gravity,Wind,Travel:TVector3;Speed:Single);
var Inverse,Change:TMatrix4; I,Steps:Integer;Delta,Accel,LocalGravity,LocalWind:TVector3;FixedStep:Single;
begin
  FixedStep:=FState.StepSeconds;if FixedStep<=0 then begin SetDetail(0);FixedStep:=FState.StepSeconds end;
  if(Dt<=0)then Exit;
  if(Dt>0.25)then begin Reset;Dt:=FixedStep end;
  if not FState.Valid then begin FState.Valid:=True;FState.Frame:=Frame;FState.LastSpeed:=Speed end;
  if not Frame.TryInverse(Inverse)then Exit;
  Change:=Inverse*FState.Frame;
  Delta:=Change.MultPoint(TVector3.Zero);
  if Delta.LengthSqr>0.25 then begin
    FState.Position:=FRest;FState.Previous:=FRest;FillChar(FState.Velocity,SizeOf(FState.Velocity),0);
  end else
    for I:=0 to HairPointCount-1 do begin
      if FPinned[I]then begin
        FState.Position[I]:=FRest[I];FState.Previous[I]:=FRest[I];FState.Velocity[I]:=TVector3.Zero;Continue;
      end;
      FState.Position[I]:=Change.MultPoint(FState.Position[I]);
      FState.Previous[I]:=Change.MultPoint(FState.Previous[I]);
      FState.Velocity[I]:=Change.MultDirection(FState.Velocity[I]);
    end;
  FState.Frame:=Frame;
  LocalGravity:=Inverse.MultDirection(Gravity);
  LocalWind:=Inverse.MultDirection(Wind);
  Accel:=Inverse.MultDirection(Travel*EnsureRange((Speed-FState.LastSpeed)/Max(Dt,0.001),-8.0,8.0));
  FState.LastSpeed:=Speed;
  FState.Remainder:=FState.Remainder+Dt;Steps:=0;
  while(FState.Remainder>=FixedStep)and(Steps<30)do begin
    Step(FixedStep,LocalGravity,LocalWind,Accel);
    FState.Remainder:=FState.Remainder-FixedStep;Inc(Steps);
  end;
end;
function TRiderHairPhysics.RenderPoint(Index:Integer):TVector3;
var T:Single;
begin
  T:=EnsureRange(FState.Remainder/Max(FState.StepSeconds,1/120),0.0,1.0);
  Result:=FState.Previous[Index]*(1-T)+FState.Position[Index]*T;
  if not FPinned[Index]and(FRest[Index].Y< -0.10)then CollideTorso(Result);
end;
function TRiderHairPhysics.MaxDisplacement:Single;
var I:Integer;
begin Result:=0;for I:=0 to HairPointCount-1 do Result:=Max(Result,(FState.Position[I]-FRest[I]).Length) end;
function TRiderHairPhysics.ActiveGuideCount:Integer;
var I:Integer;
begin
  Result:=0;for I:=0 to HairGuideCount-1 do if FProxy[FState.DetailLevel,I]=I then Inc(Result);
end;
function TRiderHairPhysics.MaxLengthError:Single;
var I,J,K:Integer;
begin
  Result:=0;
  for I:=0 to HairGuideCount-1 do for J:=1 to HairGuidePoints-1 do begin
    K:=I*HairGuidePoints+J;
    Result:=Max(Result,Abs((FState.Position[K]-FState.Position[K-1]).Length-(FRest[K]-FRest[K-1]).Length));
  end;
end;
end.
