unit GameFitLoadReference;
{$mode objfpc}{$H+}

interface

uses FitFile, GameFitLoadProfile, Osm3dFitHeightLayer;

{ Build the load reference from the same GPS-indexed records as the route.
  Keep the FIT odometer wherever it advances. A frozen/missing counter may
  still contain a moving GPS track; recover those spans before differentiating
  altitude, rather than compressing their entire climb into the next record. }
function BuildFitLoadReference(const Points: TFitGeoAltArray;
  Datum: TFitHeightLayer; ClosingM: Double): TFitLoadProfile;

implementation

uses Math, Osm3dGeoMath;

function LoadDistances(const Points: TFitGeoAltArray;
  out RepairedSpans: Integer; out RecoveredM: Double): TFitLoadValues;
const
  CounterEpsilonM = 0.01;
  MinGpsTravelM = 30.0;
var
  CounterM, GpsM: TFitLoadValues;
  I, A, B, K, N: Integer;
  Recorded, Travel, Replacement, Scale, Base, X: Double;

  function CounterStep(Index: Integer): Double;
  begin
    Result := CounterM[Index]-CounterM[Index-1];
  end;

  function Distance(AIndex, BIndex: Integer): Double;
  begin
    Result := TLatLon.Make(Points[AIndex].Lat,Points[AIndex].Lon).DistanceTo(
      TLatLon.Make(Points[BIndex].Lat,Points[BIndex].Lon));
    if IsNan(Result) or IsInfinite(Result) then Result := 0;
  end;

  function Moved(AIndex,BIndex:Integer;MinimumM:Double):Boolean;
  var J,FarSamples:Integer;
  begin
    if Distance(AIndex,BIndex)>=MinimumM then Exit(True);
    FarSamples:=0;
    for J:=AIndex+1 to BIndex-1 do
      if Distance(AIndex,J)>=MinimumM then
      begin
        Inc(FarSamples);
        if FarSamples>=3 then Exit(True);
      end;
    Result:=False;
  end;

begin
  Result := nil; RepairedSpans := 0; RecoveredM := 0;
  N := Length(Points);
  SetLength(Result,N); SetLength(GpsM,N); SetLength(CounterM,N);
  if N=0 then Exit;
  Base:=Points[0].DistanceM;
  if IsNan(Base) or IsInfinite(Base) then Base:=0;
  for I:=1 to N-1 do
  begin
    X:=Points[I].DistanceM-Base;
    if IsNan(X) or IsInfinite(X) then X:=CounterM[I-1];
    CounterM[I]:=Max(CounterM[I-1],X);
    GpsM[I]:=GpsM[I-1]+Distance(I-1,I);
  end;
  { Preserve GPS-only routes, including short ones, when there is no usable
    odometer at all. A stationary cloud of fixes still has no travel. }
  if CounterM[N-1]<=20 then
  begin
    if Moved(0,N-1,20) then
    begin
      Result:=GpsM;RepairedSpans:=1;
      RecoveredM:=GpsM[N-1]-CounterM[N-1];
    end;
    Exit;
  end;
  I:=1;
  while I<N do
  begin
    Recorded:=CounterStep(I);
    if Recorded>CounterEpsilonM then
    begin
      Result[I]:=Result[I-1]+Recorded; Inc(I); Continue;
    end;
    A:=I-1; B:=I;
    while (B<N-1) and (CounterStep(B)<=CounterEpsilonM) do Inc(B);
    Recorded:=0;
    for K:=A+1 to B do Recorded:=Recorded+CounterStep(K);
    Travel:=GpsM[B]-GpsM[A];
    { Actual displacement, not accumulated GPS jitter at a stop. Several
      displaced fixes also recognize loops without trusting a lone GPS spike.
      Include the first advancing sample: a delayed odometer may catch up
      there. Redistribute that distance without adding it a second time. }
    if Moved(A,B,MinGpsTravelM) and
       (Travel>CounterEpsilonM) and
       (Recorded<=Travel*4.0) then
    begin
      if Recorded<Travel*0.25 then Replacement:=Travel
      else Replacement:=Recorded;
      Scale:=Replacement/Travel;
      for K:=A+1 to B do
        Result[K]:=Result[A]+(GpsM[K]-GpsM[A])*Scale;
      Inc(RepairedSpans); RecoveredM:=RecoveredM+Replacement-Recorded;
    end else
      for K:=A+1 to B do Result[K]:=Result[K-1]+CounterStep(K);
    I:=B+1;
  end;
end;

function BuildFitLoadReference(const Points: TFitGeoAltArray;
  Datum: TFitHeightLayer; ClosingM: Double): TFitLoadProfile;
var D,H:TFitLoadValues; I,Repaired:Integer; Recovered:Double;
  Calibrated:Boolean;
begin
  Result:=Default(TFitLoadProfile);
  if Length(Points)<2 then Exit;
  D:=LoadDistances(Points,Repaired,Recovered);
  SetLength(H,Length(Points));
  Calibrated:=(Datum<>nil) and Datum.HasSelectedDatum;
  for I:=0 to High(Points) do
  begin
    if Points[I].HasAltitude then H[I]:=Points[I].AltM else H[I]:=NaN;
    if Calibrated and Points[I].HasAltitude then
      Datum.CorrectSelectedAltitude(Points[I].TimeSec,Points[I].AltM,H[I]);
  end;
  Result:=BuildFitLoadProfile(D,H,ClosingM);
  Result.DatumCorrected:=Calibrated;
  Result.DistanceRepairSpans:=Repaired;
  Result.RecoveredDistanceM:=Recovered;
end;

end.
