unit GameFitLoadProfile;
{$mode objfpc}{$H+}

interface

type
  TFitLoadValues = array of Double;
  { Immutable after construction; paths/bots share the reference-counted arrays.
    Stations are ORIGINAL FIT distance, never render height or elapsed time. }
  TFitLoadProfile = record
    StationM: TFitLoadValues;
    HeightM, GradeSin: TFitLoadValues;
    StepM, LengthM, ClosingM, LoopDriftM: Double;
    RejectedSpikes, StationarySamples: Integer;
    DatumCorrected: Boolean;
  end;

function BuildFitLoadProfile(const DistanceM, AltitudeM: array of Double;
  ClosingM: Double = 0): TFitLoadProfile;
function FitLoadAt(const Profile: TFitLoadProfile; Station: Double;
  out HeightM, GradePct: Single): Boolean;
function FitLoadStationAtIndex(const Profile: TFitLoadProfile;
  SourceIndex: Double): Double;
{ Regularize the FIT correspondence in metres of the prepared path. Snapping
  may collapse many FIT samples to one point; their source distance must not
  become an instantaneous jump in trainer load. Endpoints remain anchored.
  Periodic input includes the closing endpoint with its unwrapped station. }
function SmoothFitSourceStations(const PathM, SourceM: array of Double;
  Periodic: Boolean): TFitLoadValues;

implementation

uses Math;

function Finite(X: Double): Boolean; inline;
begin Result:=not(IsNan(X) or IsInfinite(X)) end;

function SmoothFitSourceStations(const PathM, SourceM: array of Double;
  Periodic: Boolean): TFitLoadValues;
const HalfWindowM = 10.0;
var
  X, Area: TFitLoadValues;
  I, N: Integer;
  Total, HalfWindow, Span, Cycle, Offset, Lower, Upper: Double;

  function InsideIntegral(S: Double): Double;
  var Lo, Hi, Mid: Integer; D, Len: Double;
  begin
    if S <= 0 then Exit(0);
    if S >= Total then Exit(Area[N-1]);
    Lo := 0; Hi := N-1;
    while Lo+1 < Hi do
    begin
      Mid := (Lo+Hi) div 2;
      if X[Mid] <= S then Lo := Mid else Hi := Mid;
    end;
    { Upper-bound search skips coincident points. Their zero-length steps
      contribute zero area; no division by an artificial minimum length. }
    D := S-X[Lo]; Len := X[Hi]-X[Lo];
    Result := Area[Lo]+SourceM[Lo]*D+
      0.5*(SourceM[Hi]-SourceM[Lo])*D*D/Len;
  end;

  function Integral(S: Double): Double;
  begin
    if S < 0 then
    begin
      if Periodic then
        Exit(InsideIntegral(S+Total)-Area[N-1]-Cycle*S)
      else
        Exit(InsideIntegral(-S)+2*SourceM[0]*S);
    end;
    if S > Total then
    begin
      if Periodic then
        Exit(Area[N-1]+InsideIntegral(S-Total)+Cycle*(S-Total))
      else
        Exit(InsideIntegral(2*Total-S)+2*SourceM[N-1]*(S-Total));
    end;
    Result := InsideIntegral(S);
  end;

begin
  Result := nil;
  N := Length(SourceM);
  SetLength(Result, N);
  for I := 0 to N-1 do Result[I] := SourceM[I];
  if (N < 2) or (Length(PathM) <> N) then Exit;
  SetLength(X, N); SetLength(Area, N);
  for I := 0 to N-1 do
  begin
    if not Finite(PathM[I]) or not Finite(SourceM[I]) then Exit;
    X[I] := PathM[I]-PathM[0];
    if I = 0 then Continue;
    Span := X[I]-X[I-1];
    if Span < 0 then Exit;
    Area[I] := Area[I-1]+0.5*(SourceM[I-1]+SourceM[I])*Span;
  end;
  Total := X[N-1];
  if Total < 0.001 then Exit;
  HalfWindow := Min(HalfWindowM, Total*0.25);
  Cycle := SourceM[N-1]-SourceM[0];
  Offset := 0;
  if Periodic then
    Offset := (Integral(HalfWindow)-Integral(-HalfWindow))/(2*HalfWindow)-SourceM[0];
  Lower := Min(SourceM[0],SourceM[N-1]);
  Upper := Max(SourceM[0],SourceM[N-1]);
  for I := 0 to N-1 do
    Result[I] := EnsureRange((Integral(X[I]+HalfWindow)-
      Integral(X[I]-HalfWindow))/(2*HalfWindow)-Offset, Lower, Upper);
  Result[0] := SourceM[0]; Result[N-1] := SourceM[N-1];
end;

function BuildFitLoadProfile(const DistanceM, AltitudeM: array of Double;
  ClosingM: Double): TFitLoadProfile;
const GridM=2.0; SmoothHalfM=10.0; GradeHalfM=10.0; MaxGrid=262144;
var
  D,H,Raw,First,Smoothed: TFitLoadValues;
  I,N,Count,Radius: Integer;
  Base,Last,Total,GridStep,X,F,Expected,Span,LeftSlope,RightSlope,
    EndSlope,Drift,StartHeight: Double;

  function SourceHeight(S: Double): Double;
  var Lo,Hi,M: Integer;
  begin
    if S<=D[0] then Exit(H[0]+(S-D[0])*LeftSlope);
    if S>=D[Count-1] then Exit(H[Count-1]+(S-D[Count-1])*RightSlope);
    Lo:=0;Hi:=Count-1;
    while Lo+1<Hi do begin M:=(Lo+Hi) div 2;if D[M]<=S then Lo:=M else Hi:=M end;
    Result:=H[Lo]+(H[Hi]-H[Lo])*(S-D[Lo])/(D[Hi]-D[Lo]);
  end;

  function At(const Values: TFitLoadValues; S: Double): Double;
  var K:Integer; U:Double;
  begin
    if ClosingM>0 then begin
      S:=S-Floor(S/Total)*Total;
      U:=S/GridStep;K:=Min(N-1,Floor(U));
      Exit(Values[K]+(Values[(K+1) mod N]-Values[K])*(U-K));
    end;
    U:=S/GridStep;
    if U<0 then Exit(Values[0]+S*LeftSlope);
    if U>=N-1 then Exit(Values[N-1]+(S-Total)*RightSlope);
    K:=Floor(U);Result:=Values[K]+(Values[K+1]-Values[K])*(U-K);
  end;

  procedure Average(const Input: TFitLoadValues; out Output: TFitLoadValues);
  var K,L:Integer;Sum:Double;
  begin
    SetLength(Output,N);
    Sum:=0;for L:=-Radius to Radius do Sum:=Sum+At(Input,L*GridStep);
    for K:=0 to N-1 do begin
      Output[K]:=Sum/(2*Radius+1);
      Sum:=Sum-At(Input,(K-Radius)*GridStep)+At(Input,(K+Radius+1)*GridStep);
    end;
  end;

begin
  Result:=Default(TFitLoadProfile);
  if (Length(DistanceM)<2) or (Length(DistanceM)<>Length(AltitudeM)) then Exit;
  SetLength(Result.StationM,Length(DistanceM));
  Base:=DistanceM[0];Last:=0;
  if not Finite(Base) then Base:=0;
  SetLength(D,Length(DistanceM)+1);SetLength(H,Length(D));Count:=0;
  for I:=0 to High(DistanceM) do begin
    X:=DistanceM[I]-Base;
    if not Finite(X) then X:=Last;
    X:=Max(Last,X);Result.StationM[I]:=X;Last:=X;
    if not Finite(AltitudeM[I]) then Continue;
    if (Count>0) and (X-D[Count-1]<0.1) then begin Inc(Result.StationarySamples);Continue end;
    D[Count]:=X;H[Count]:=AltitudeM[I];Inc(Count);
  end;
  if (Count<2) or (Last<20) then begin Result:=Default(TFitLoadProfile);Exit end;
  { Reject isolated impossible altitude spikes, not power/speed discrepancies.
    A genuine sustained steep slope survives: the two sides must reverse. }
  First:=Copy(H,0,Count);
  for I:=1 to Count-2 do begin
    Span:=D[I+1]-D[I-1];
    Expected:=First[I-1]+(First[I+1]-First[I-1])*(D[I]-D[I-1])/Span;
    if ((First[I]-First[I-1])*(First[I+1]-First[I])<0) and
       (Min(Abs((First[I]-First[I-1])/(D[I]-D[I-1])),
            Abs((First[I+1]-First[I])/(D[I+1]-D[I])))>0.7) and
       (Abs(First[I]-Expected)>Max(3.0,Span*0.3)) then begin
      H[I]:=Expected;Inc(Result.RejectedSpikes);
    end;
  end;
  LeftSlope:=(H[1]-H[0])/(D[1]-D[0]);
  RightSlope:=(H[Count-1]-H[Count-2])/(D[Count-1]-D[Count-2]);
  ClosingM:=Max(0,ClosingM);
  if ClosingM>0 then begin
    ClosingM:=Max(ClosingM,2.0);
    { A small accumulated altitude drift must not all become a steep ramp
      on the short connector of a lap. Only reconcile a closure inconsistent
      with the measured end gradients, and never change sustained grades by
      more than 0.2 percentage points. Large real elevation differences stay.
      The correction is a constant, very small gradient over the WHOLE lap. }
    if (D[0]<0.1) and (Last-D[Count-1]<0.1) then begin
      Span:=Min(20.0,Last*0.5);
      EndSlope:=0.5*((SourceHeight(Span)-H[0])/Span+
        (H[Count-1]-SourceHeight(Last-Span))/Span);
      Drift:=H[Count-1]-H[0]+EndSlope*ClosingM;
      if (Abs((H[0]-H[Count-1])/ClosingM-EndSlope)>0.08) and
         (Abs(Drift)/(Last+ClosingM)<=0.002) then begin
        Result.LoopDriftM:=Drift;
        F:=Drift/(Last+ClosingM);
        for I:=0 to Count-1 do H[I]:=H[I]-F*D[I];
        LeftSlope:=LeftSlope-F;RightSlope:=RightSlope-F;
      end;
    end;
    { The connector is part of the profile; periodic filtering also makes
      the load continuous across the boundary between laps. Missing initial
      altitude is extrapolated at station zero, just as on the first lap. }
    StartHeight:=SourceHeight(0);
    D[Count]:=Last+ClosingM;H[Count]:=StartHeight;Inc(Count);
  end;
  Total:=Last+ClosingM;Result.LengthM:=Total;Result.ClosingM:=ClosingM;
  N:=Min(MaxGrid,Max(2,Ceil(Total/GridM)));
  if ClosingM>0 then Result.StepM:=Total/N
  else begin Inc(N);Result.StepM:=Total/(N-1) end;
  GridStep:=Result.StepM;
  SetLength(Raw,N);
  for I:=0 to N-1 do Raw[I]:=SourceHeight(I*Result.StepM);
  Radius:=Max(1,Round(SmoothHalfM/Result.StepM));
  { Two centred distance averages form a triangular filter (~44 m support).
    Each metre has the same weight; a long stop cannot dominate the filter. }
  Average(Raw,First);Average(First,Smoothed);
  Result.HeightM:=Smoothed;
  SetLength(Result.GradeSin,N);
  for I:=0 to N-1 do begin
    X:=I*Result.StepM;
    F:=(At(Smoothed,X+GradeHalfM)-At(Smoothed,X-GradeHalfM))/(2*GradeHalfM);
    { FIT distance is travelled length, so dh/ds=sin(theta), not tan(theta). }
    Result.GradeSin[I]:=EnsureRange(F,-0.7,0.7);
  end;
end;

function FitLoadAt(const Profile: TFitLoadProfile; Station: Double;
  out HeightM, GradePct: Single): Boolean;
var I,J,N:Integer;U,F,G:Double;
begin
  HeightM:=0;GradePct:=0;N:=Length(Profile.HeightM);
  Result:=(N>=2) and (Profile.StepM>0) and Finite(Station);
  if not Result then Exit;
  if Profile.ClosingM>0 then Station:=Station-Floor(Station/Profile.LengthM)*Profile.LengthM
  else Station:=EnsureRange(Station,0.0,Profile.LengthM);
  U:=Station/Profile.StepM;I:=Min(N-1,Floor(U));F:=U-I;J:=Min(N-1,I+1);
  if Profile.ClosingM>0 then J:=(I+1) mod N;
  HeightM:=Profile.HeightM[I]+(Profile.HeightM[J]-Profile.HeightM[I])*F;
  G:=Profile.GradeSin[I]+(Profile.GradeSin[J]-Profile.GradeSin[I])*F;
  GradePct:=100*G/Sqrt(Max(1e-12,1-G*G));
end;

function FitLoadStationAtIndex(const Profile: TFitLoadProfile;
  SourceIndex: Double): Double;
var I,N:Integer;F,B:Double;
begin
  Result:=0;N:=Length(Profile.StationM);if N=0 then Exit;
  SourceIndex:=EnsureRange(SourceIndex,0.0,Double(N));
  I:=Min(N-1,Floor(SourceIndex));F:=Min(1.0,SourceIndex-I);
  if I<N-1 then B:=Profile.StationM[I+1] else B:=Profile.LengthM;
  Result:=Profile.StationM[I]+(B-Profile.StationM[I])*F;
end;

end.
