program FitLoadReferenceTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,FitFile,GameFitLoadProfile,GameFitLoadReference,
  Osm3dGeoMath,Osm3dFitHeightLayer;
var Checks:Integer;
procedure Check(B:Boolean;const Msg:string);
begin Inc(Checks);if not B then raise Exception.Create(Msg) end;

function Point(Metres,Counter,Height,Time:Double):TFitGeoAltPoint;
begin
  Result:=Default(TFitGeoAltPoint);
  Result.Lat:=0; Result.Lon:=RadToDeg(Metres/6371000.0);
  Result.DistanceM:=Counter;Result.AltM:=Height;Result.HasAltitude:=True;
  Result.TimeSec:=Time;
end;

procedure CheckSame(const A,B:TFitLoadProfile;const Msg:string);
var I:Integer;
begin
  Check(Length(A.HeightM)=Length(B.HeightM),Msg+' grid length');
  Check(Length(A.StationM)=Length(B.StationM),Msg+' source length');
  Check(Abs(A.LengthM-B.LengthM)<1e-8,Msg+' distance');
  for I:=0 to High(A.HeightM) do
    Check((Abs(A.HeightM[I]-B.HeightM[I])<1e-8) and
      (Abs(A.GradeSin[I]-B.GradeSin[I])<1e-8),Msg+' load');
  for I:=0 to High(A.StationM) do
    Check(Abs(A.StationM[I]-B.StationM[I])<1e-8,Msg+' station');
end;

procedure ReferenceTests;
var G:TFitGeoAltArray; D,H:TFitLoadValues; P,Q:TFitLoadProfile;
  I,N:Integer;Y,Grade:Single; Datum:TFitHeightLayer;
begin
  N:=201;SetLength(G,N);SetLength(D,N);SetLength(H,N);
  for I:=0 to N-1 do
  begin
    D[I]:=I*5; H[I]:=100+D[I]*0.04;
    { A healthy wheel odometer need not exactly match GPS length. }
    G[I]:=Point(D[I]*1.02,D[I]+13000,H[I],I);
  end;
  P:=BuildFitLoadProfile(D,H);Q:=BuildFitLoadReference(G,nil,0);
  Check(Q.DistanceRepairSpans=0,'healthy odometer was replaced by GPS');
  CheckSame(P,Q,'healthy odometer');

  { April 27 failure: distance is frozen while the route changes position
    and altitude, then starts counting from zero hundreds of metres later. }
  for I:=0 to N-1 do
    G[I]:=Point(D[I],Max(0,D[I]-500),H[I],I);
  Q:=BuildFitLoadReference(G,nil,0);
  Check(Q.DistanceRepairSpans=1,'frozen leading counter not repaired');
  Check(Abs(Q.RecoveredDistanceM-500)<0.01,'wrong recovered prefix');
  Check(Abs(Q.LengthM-1000)<0.01,'prefix still collapsed into first moving sample');
  for I:=0 to N-1 do
  begin
    FitLoadAt(Q,I*5,Y,Grade);
    Check(Abs(Grade-4.003204)<0.001,'frozen prefix made a false hill');
    Check(Abs(Q.StationM[I]-I*5)<0.01,'source index no longer matches route');
  end;

  { Same loss in the middle, and on a route whose distance field is absent. }
  for I:=0 to N-1 do
    G[I]:=Point(D[I],D[I]-EnsureRange(D[I]-250,0.0,250.0),H[I],I);
  Q:=BuildFitLoadReference(G,nil,0);
  Check(Q.DistanceRepairSpans=1,'internal frozen counter not repaired');
  Check(Abs(Q.RecoveredDistanceM-250)<0.01,'wrong recovered internal span');
  for I:=0 to N-1 do G[I].DistanceM:=0;
  Q:=BuildFitLoadReference(G,nil,0);
  Check(Abs(Q.LengthM-1000)<0.01,'all-missing odometer lost GPS fallback');
  Q:=BuildFitLoadReference(TFitGeoAltArray.Create(
    Point(0,0,100,0),Point(25,0,101,10)),nil,0);
  Check(Abs(Q.LengthM-25)<0.01,'short GPS-only route lost its load profile');
  { Closed GPS loop, also with no distance field. }
  for I:=0 to N-1 do
  begin
    G[I]:=Point(100*Cos(I*2*Pi/(N-1)),0,100,I);
    G[I].Lat:=RadToDeg(100*Sin(I*2*Pi/(N-1))/6371000.0);
  end;
  Q:=BuildFitLoadReference(G,nil,2);
  Check((Q.LengthM>629)and(Q.LengthM<631),'missing odometer on a closed loop');

  { Delayed updates catch up with GPS: fill stations, do not double distance. }
  for I:=0 to N-1 do
    G[I]:=Point(D[I],(I div 10)*50,H[I],I);
  Q:=BuildFitLoadReference(G,nil,0);
  Check(Q.DistanceRepairSpans=20,'batched counter updates not interpolated');
  Check(Abs(Q.RecoveredDistanceM)<1e-8,'catch-up distance counted twice');
  for I:=0 to N-1 do
    Check(Abs(Q.StationM[I]-D[I])<0.01,'catch-up source correspondence');

  { Real stop: GPS wanders within a few metres; summing this noise could
    accumulate hundreds of metres, but must never turn it into travel. }
  for I:=0 to N-1 do
  begin
    if I<100 then G[I]:=Point(3*Sin(I),0,100+Sin(I)*5,I)
    else G[I]:=Point((I-99)*5,(I-99)*5,100+(I-99)*0.2,I);
    D[I]:=G[I].DistanceM;H[I]:=G[I].AltM;
  end;
  P:=BuildFitLoadProfile(D,H);Q:=BuildFitLoadReference(G,nil,0);
  Check(Q.DistanceRepairSpans=0,'GPS noise at rest invented distance');
  CheckSame(P,Q,'stationary GPS noise');
  G[40].Lon:=Point(200,0,0,0).Lon;
  Q:=BuildFitLoadReference(G,nil,0);
  Check(Q.DistanceRepairSpans=0,'one GPS outlier invented distance');
  CheckSame(P,Q,'isolated GPS outlier');

  { Missing/backward counter values do not get added a second time on return. }
  for I:=0 to N-1 do
  begin
    G[I]:=Point(I*5,I*5,100+I*0.2,I);
    D[I]:=I*5;H[I]:=G[I].AltM;
  end;
  G[30].DistanceM:=0;D[30]:=0;
  G[60].DistanceM:=NaN;D[60]:=NaN;
  P:=BuildFitLoadProfile(D,H);Q:=BuildFitLoadReference(G,nil,0);
  CheckSame(P,Q,'missing and backward odometer');

  Datum:=TFitHeightLayer.Create;
  try
    Datum.SetSelectedDatum('test',[0,200],[100,140],[110,152]);
    P:=BuildFitLoadReference(G,Datum,0);
    Q:=BuildFitLoadReference(G,nil,0);
    Check(P.DatumCorrected,'lost calibrated FIT altitude');
    FitLoadAt(P,400,Y,Grade);
    Check(Grade>4.1,'datum drift correction was bypassed');
    Check(Abs(P.StationM[100]-Q.StationM[100])<1e-8,'datum changed distance');
  finally Datum.Free end;
  Writeln('PASS FIT reference: frozen prefix/middle, missing counter, GPS loop, delayed updates, stops, outliers, datum');
end;

procedure RealFileChecks(const FileName:string);
var F:TFitFile;G:TFitGeoAltArray;D,H:TFitLoadValues;P,Q:TFitLoadProfile;
  I:Integer;Closing:Double;Y,Grade:Single;
begin
  F:=TFitFile.Create;
  try
    Check(F.LoadFromFile(FileName),'cannot read '+FileName);
    G:=F.ToGeoAltPoints;SetLength(D,Length(G));SetLength(H,Length(G));
    for I:=0 to High(G) do
    begin
      D[I]:=G[I].DistanceM;
      if G[I].HasAltitude then H[I]:=G[I].AltM else H[I]:=NaN;
    end;
    Closing:=0;
    if TLatLon.Make(G[0].Lat,G[0].Lon).DistanceTo(
      TLatLon.Make(G[High(G)].Lat,G[High(G)].Lon))<30 then Closing:=4;
    P:=BuildFitLoadProfile(D,H,Closing);
    Q:=BuildFitLoadReference(G,nil,Closing);
    if Q.DistanceRepairSpans=0 then CheckSame(P,Q,ExtractFileName(FileName));
    for I:=0 to High(Q.HeightM) do
      Check(not(IsNan(Q.HeightM[I])or IsInfinite(Q.HeightM[I])or
        IsNan(Q.GradeSin[I])or IsInfinite(Q.GradeSin[I])),'invalid real profile');
    FitLoadAt(Q,0,Y,Grade);
    Writeln(ExtractFileName(FileName),' repaired_spans=',Q.DistanceRepairSpans,
      ' recovered_m=',Q.RecoveredDistanceM:0:3,' start_grade=',Grade:0:4);
  finally F.Free end;
end;

var Arg:Integer;
begin
  ReferenceTests;
  for Arg:=1 to ParamCount do RealFileChecks(ParamStr(Arg));
  Writeln('ALL PASS ',Checks,' assertions');
end.
