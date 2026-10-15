program FitLoadProfileTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,CastleVectors,GameFitLoadProfile,GamePath,
  GamePhysicsCommon,GamePhysicsKinematic,GamePhysicsBase,
  Osm3dGeoMath,Osm3dMapUtils,Osm3dRouteBuildings,Osm3dBuildingObstacleIndex;
type
  TProbe=class(TKinematicActorPhysics)
    procedure VisualSlope(Pitch:Single);
    function Accel:Single;
  end;
  TMissingGround=class
    Calls:Integer;
    function Query(X,Z,R:Single;out Y:Single):Boolean;
  end;
var Checks:Integer;
procedure Check(B:Boolean;const Msg:string);
begin Inc(Checks);if not B then raise Exception.Create(Msg) end;
procedure TProbe.VisualSlope(Pitch:Single);
begin ApplySmoothedFitSlope(Pitch,1/30) end;
function TProbe.Accel:Single;
begin Result:=CalculateAcceleration(1/60) end;
function TMissingGround.Query(X,Z,R:Single;out Y:Single):Boolean;
begin Inc(Calls);Y:=0;Result:=False end;

procedure ProfileTests;
var D,H,SD,SH:TFitLoadValues;P,Q:TFitLoadProfile;I,J,K:Integer;
  Y,G,G2,Y2:Single;Expected,Lo,Hi,Integral:Double;
begin
  SetLength(D,501);SetLength(H,501);
  for I:=0 to High(D) do begin D[I]:=I*2;H[I]:=120+D[I]*0.08 end;
  P:=BuildFitLoadProfile(D,H);Expected:=100*0.08/Sqrt(1-Sqr(0.08));
  for I:=0 to 100 do begin
    Check(FitLoadAt(P,I*10,Y,G),'missing linear height');
    Check(Abs(G-Expected)<0.0001,'constant incline changed at endpoint');
    Check(Abs(Y-(120+I*0.8))<0.0001,'linear elevation changed');
  end;
  { Repeated time samples at a stop must not get extra spatial weight. }
  SetLength(SD,1001);SetLength(SH,1001);K:=0;
  for I:=0 to High(D) do begin
    SD[K]:=D[I];SH[K]:=H[I];Inc(K);
    if I=250 then for J:=1 to 500 do begin
      SD[K]:=D[I];SH[K]:=H[I]+Sin(J)*20;Inc(K);
    end;
  end;
  Q:=BuildFitLoadProfile(SD,SH);
  Check(Q.StationarySamples=500,'stop samples not collapsed');
  for I:=0 to 100 do begin
    FitLoadAt(P,I*10,Y,G);FitLoadAt(Q,I*10,Y2,G2);
    Check((Abs(G-G2)<1e-6)and(Abs(Y-Y2)<1e-6),'stationary barometer made a hill');
  end;
  H[250]:=H[250]+100;Q:=BuildFitLoadProfile(D,H);
  Check(Q.RejectedSpikes=1,'altitude spike not rejected');
  FitLoadAt(Q,500,Y,G);Check(Abs(G-Expected)<0.0001,'spike changed sustained load');
  for I:=0 to High(D) do H[I]:=100+0.08*Min(D[I],1000-D[I]);
  P:=BuildFitLoadProfile(D,H);FitLoadAt(P,500,Y,G);
  Check(Abs(G)<0.0001,'centred filter displaced crest');
  FitLoadAt(P,450,Y,G);Check(G>7.9,'sustained climb flattened');
  FitLoadAt(P,550,Y,G);Check(G< -7.9,'descent flattened');
  for I:=0 to High(D) do H[I]:=100+Sin(D[I]*2*Pi/1000)*10;
  P:=BuildFitLoadProfile(D,H,2);
  FitLoadAt(P,0,Y,G);FitLoadAt(P,P.LengthM,Y2,G2);
  Check((Abs(Y-Y2)<1e-6)and(Abs(G-G2)<1e-6),'closed lap has load seam');
  Integral:=0;
  for I:=0 to High(P.GradeSin) do Integral:=Integral+P.GradeSin[I]*P.StepM;
  Check(Abs(Integral)<0.001,'closed lap invented net elevation');
  { Six metres of drift over a long lap are not a 30% descent on its
    twenty-metre connector. Preserve real hills and reconcile the datum. }
  for I:=0 to High(D) do begin
    D[I]:=I*20;H[I]:=100+10*Sin(D[I]*2*Pi/10000)+D[I]*0.0006;
  end;
  P:=BuildFitLoadProfile(D,H,20);
  Check((P.LoopDriftM>6)and(P.LoopDriftM<6.2),'small lap drift was not reconciled');
  for I:=0 to 20 do begin
    FitLoadAt(P,P.LengthM-20+I,Y,G);
    Check(Abs(G)<0.8,'lap closure invented a steep ramp');
  end;
  Integral:=0;
  for I:=0 to High(P.GradeSin) do Integral:=Integral+P.GradeSin[I]*P.StepM;
  Check(Abs(Integral)<0.001,'drift correction left net elevation on closed lap');
  Q:=BuildFitLoadProfile(D,H);
  Check(Q.LoopDriftM=0,'open route elevation was flattened to close a loop');
  for I:=0 to High(D) do begin D[I]:=I*2;H[I]:=100+0.08*D[I] end;
  Q:=BuildFitLoadProfile(D,H,2);
  Check(Q.LoopDriftM=0,'large real height difference mistaken for barometer drift');
  for I:=0 to High(H) do H[I]:=100+0.06*D[I]+0.1*Sin(I*2);
  P:=BuildFitLoadProfile(D,H);Lo:=100;Hi:=-100;
  for I:=5 to 95 do begin FitLoadAt(P,I*10,Y,G);Lo:=Min(Lo,G);Hi:=Max(Hi,G) end;
  Check(Hi-Lo<0.15,'small altitude quantization reaches trainer');
  for I:=0 to High(H) do H[I]:=NaN;
  Q:=BuildFitLoadProfile(D,H);Check(not FitLoadAt(Q,10,Y,G),'missing altitude treated as zero');
  Writeln('PASS profile: linear incline, endpoints, stops, spikes, crest, closed seam, missing altitude');
end;

procedure CorrespondenceTests;
var X,S,A,B:TFitLoadValues;I:Integer;G,Y:Single;P,Q:TFitLoadProfile;
begin
  X:=TFitLoadValues.Create(0,1,2,10,40,100,400,1000);
  SetLength(S,Length(X));
  for I:=0 to High(X) do S[I]:=2*X[I];
  for I:=0 to 1 do
  begin
    A:=SmoothFitSourceStations(X,S,I=1);
    Check(Length(A)=Length(S),'mapping size changed');
    Check(Abs(A[3]-S[3])<1e-8,'regular spacing was displaced');
    Check(Abs(A[High(A)]-S[High(S)])<1e-8,'end station moved');
  end;
  { Snapping compressed ten FIT metres into one coincident road point.
    Filtering in metres, rather than sample count, spreads that jump. }
  X:=TFitLoadValues.Create(0,30,49,50,50,51,70,100);
  S:=TFitLoadValues.Create(0,30,49,50,60,61,80,110);
  A:=SmoothFitSourceStations(X,S,False);
  Check((A[0]=0)and(A[High(A)]=110),'open endpoints lost');
  Check(Abs(A[3]-A[4])<1e-8,'coincident points retain different FIT stations');
  Check(A[5]-A[2]<4,'ten-metre FIT jump remains across two road metres');
  for I:=1 to High(A) do Check(A[I]>=A[I-1],'mapping reversed on outbound leg');
  for I:=0 to High(X) do begin X[I]:=X[I]+100000;S[I]:=110-S[I] end;
  B:=SmoothFitSourceStations(X,S,False);
  for I:=0 to High(A) do Check(Abs(B[I]-(110-A[I]))<1e-6,'return leg or distance origin changed smoothing');
  S:=TFitLoadValues.Create(0,30,49,50,60,61,80,110);
  A:=SmoothFitSourceStations(X,S,True);
  Check((A[0]=0)and(A[High(A)]=110),'periodic start or end phase lost');
  for I:=1 to High(A) do Check(A[I]>=A[I-1],'periodic mapping reversed');
  Check(Abs(A[3]-A[4])<1e-8,'periodic coincident samples retain a jump');
  Writeln('PASS correspondence: nonuniform spacing, coincident points, anchored endpoints, periodic lap, return leg');

  { Missing altitude at the beginning must not copy the first known height
    onto the end of a closed lap. Both complete flanks are linear here. }
  SetLength(X,501);SetLength(S,501);
  for I:=0 to High(X) do begin X[I]:=I*2;S[I]:=100+0.05*Min(X[I],1000-X[I]) end;
  P:=BuildFitLoadProfile(X,S,20);
  for I:=0 to 19 do S[I]:=NaN;
  Q:=BuildFitLoadProfile(X,S,20);
  for I:=0 to High(P.HeightM) do
    Check(Abs(P.HeightM[I]-Q.HeightM[I])<1e-6,'missing initial altitude changed lap seam');
  FitLoadAt(Q,0,Y,G);
  Check(not IsNan(G),'missing first altitude produced invalid load');
  Writeln('PASS closed lap with missing initial altitude');
end;

procedure MappingAndPhysicsTests;
var Proj:TLocalProjection; Ob:TBuildingObstacleIndex;
  Centers,Ride:TRouteLatLonArray; W,RW:TRouteWidthArray; Src:TRouteSourceArray;
  Local:array of TVector3; D,H:TFitLoadValues;P:TFitLoadProfile;
  Path,Bot:TGamePath;State:TPhysicsState;Probe:TProbe;Ground:TMissingGround;
  Pos:TPathPosition;I,N,Detours:Integer;G,S,Y,A,Expected:Single;
  Buildings:TBuildingObstacleArray;
begin
  Proj:=TLocalProjection.Create(TLatLon.Make(55,37));Ob:=TBuildingObstacleIndex.Create;
  Path:=TGamePath.Create;Bot:=TGamePath.Create;State:=TPhysicsState.Create;
  Ground:=TMissingGround.Create;Probe:=TProbe.Create(nil,State,Path,nil,nil);
  try
    SetLength(Centers,3);SetLength(W,3);SetLength(D,3);SetLength(H,3);
    for I:=0 to 2 do begin
      Centers[I]:=Proj.Unproject(0,I*200);W[I]:=6;D[I]:=I*200;H[I]:=50+I*16;
    end;
    SetLength(Buildings,1);SetLength(Buildings[0].Footprint,4);
    Buildings[0].Footprint[0]:=Vector3(-5,0,90);Buildings[0].Footprint[1]:=Vector3(-5,0,110);
    Buildings[0].Footprint[2]:=Vector3(5,0,110);Buildings[0].Footprint[3]:=Vector3(5,0,90);
    Buildings[0].MaxY:=10;RebuildObstacleAABB(Buildings[0]);Ob.AddObstacles(Buildings,1);
    PrepareBuildingSafeRoute(Centers,W,Proj,Ob,Ride,RW,Detours,@Src);
    Check(Detours>0,'test did not exercise building detour');N:=Length(Ride);
    Check(Length(Src)=N,'missing source mapping');Check(Abs(Src[N div 2]-2)<1e-6,'endpoint correspondence lost');
    SetLength(Local,N);for I:=0 to N-1 do Local[I]:=Proj.Project(Ride[I]);
    P:=BuildFitLoadProfile(D,H);P.DatumCorrected:=True;
    Path.LoadFromMemory(Local,RW);Path.UsePreparedCornerHints(True);
    Path.SetFitLoadProfile(P,Src);Path.CopyTo(Bot);Path.Clear;
    Check(Bot.HasFitLoadProfile,'copy lost shared profile after original clear');
    Check(Bot.FitLoadDatumCorrected,'copy lost calibrated height provenance');
    Bot.CopyTo(Path);Expected:=100*0.08/Sqrt(1-Sqr(0.08));
    for I:=0 to N-1 do begin
      Pos.Segment:=I;Pos.T:=0.5;Path.Position:=Pos;
      Check(Path.FitLoadAtPosition(Pos,G,S,Y),'prepared point missing load');
      if I<N div 2 then Check(Abs(G-Expected)<0.001,'outbound detour changed gradient')
      else Check(Abs(G+Expected)<0.001,'return gradient did not reverse');
      if I>0 then Check(Abs(Src[I]-Src[N-I])<1e-6,'reversed detour source mismatch');
    end;
    State.GroundQuery:=@Ground.Query;State.SlopeQuery:=@Ground.Query;
    State.CurrentSpeed:=5;State.AvatarMass:=85;State.AppliedPowerWatts:=200;
    Pos.Segment:=1;Pos.T:=0.3;Path.Position:=Pos;
    Probe.VisualSlope(-25);A:=Probe.Accel;
    Check(Abs(Tan(DegToRad(State.CurrentSlopeAngle))*100-Expected)<0.001,'OSM descent overrode FIT climb');
    Probe.VisualSlope(35);
    Check(Abs(A-Probe.Accel)<1e-6,'rendered slope changed acceleration');
    Check(Ground.Calls=0,'FIT load sampled missing GPU surface');
    Check(Probe.CaptureReplay.ElevDebtM=0,'FIT profile retained elevation debt');
    Check(not State.CurrentSlopeCorrValid,'new absolute load shown as old correction');
    Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,100)],[6,6]);
    Check(not Path.HasFitLoadProfile,'new route retained previous load');
    Writeln('PASS mapping/physics: detour, reverse, copied bot, missing GPU, opposite OSM slope, route reset');
  finally Probe.Free;Ground.Free;State.Free;Bot.Free;Path.Free;Ob.Free;Proj.Free end;
end;
begin
  ProfileTests;CorrespondenceTests;MappingAndPhysicsTests;Writeln('ALL PASS ',Checks,' assertions');
end.
