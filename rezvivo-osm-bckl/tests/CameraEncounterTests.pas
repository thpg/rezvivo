program CameraEncounterTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,CastleVectors,CastleTransform,CastleViewport,CastleCameras,
  GameCameraEncounters,GameCinematicCamera,GameSimCameraTrack;
type TSceneProbe=class
  Ready,Blocked,BlockTravel:Boolean;
  function Ground(X,Z,ReferenceY:Single;out Y:Single):Boolean;
  function ClearPath(const A,B:TVector3):Boolean;
end;
function TSceneProbe.Ground(X,Z,ReferenceY:Single;out Y:Single):Boolean;
begin Y:=0;Result:=Ready end;
function TSceneProbe.ClearPath(const A,B:TVector3):Boolean;
begin
  Result:=not Blocked;
  { A wall between old and new cameras does not hide the subject from the
    destination. It must reject a flight but never reject an editorial cut. }
  if BlockTravel and (B.Y>1.1) then Result:=False;
end;
procedure Check(V:Boolean;const Message:string);
begin if not V then raise Exception.Create(Message)end;
procedure Near(A,B,Epsilon:Single;const Message:string);
begin Check(Abs(A-B)<=Epsilon,Format('%s %.5f / %.5f',[Message,A,B]))end;

procedure Encounter(OwnSpeed,OtherSpeed,Start,OtherDirection,Lateral,Height:Single;
  Expected:TCameraEncounterKind);
var State:TCameraEncounterTracker;Riders:array[0..0]of TCameraRider;
  I,Index,Count:Integer;Kind,Found:TCameraEncounterKind;T:Single;
begin
  State:=Default(TCameraEncounterTracker);Riders[0]:=Default(TCameraRider);
  Riders[0].Id:=42;Riders[0].Direction:=Vector3(0,0,OtherDirection);
  Riders[0].Speed:=OtherSpeed;Count:=0;Found:=ceNone;
  for I:=0 to 240 do begin
    T:=I/60;Riders[0].Position:=Vector3(Lateral,Height,Start+OtherDirection*OtherSpeed*T);
    Index:=UpdateCameraEncounters(State,Riders,1,Vector3(0,0,OwnSpeed*T),
      Vector3(0,0,1),OwnSpeed,1/60,True,Kind);
    if Index>=0 then begin Inc(Count);Found:=Kind end;
  end;
  Check(Found=Expected,'incorrect encounter classification '+IntToStr(Ord(Expected)));
  if Expected=ceNone then Check(Count=0,'non-encounter selected')
  else Check(Count=1,'same pass selected repeatedly');
  { Reset the relative motion repeatedly without removing the rider. Even
    after the global cooldown, the same actor cannot dominate the sequence. }
  if Expected<>ceNone then for I:=1 to 7200 do begin
    T:=(I mod 180)/60;
    Riders[0].Position:=Vector3(Lateral,Height,Start+OtherDirection*OtherSpeed*T);
    Index:=UpdateCameraEncounters(State,Riders,1,Vector3(0,0,OwnSpeed*T),
      Vector3(0,0,1),OwnSpeed,1/60,True,Kind);
    Check(Index<0,'present rider retriggered after global cooldown');
  end;
end;

var View:TCastleViewport;Target:TCastleTransform;Camera:TCinematicCamera;
  Probe:TSceneProbe;I,Phase,Fps:Integer;P,D,U,Prev,ExpectedP,ExpectedD,Rider,Offset:TVector3;
  Saved:TCameraReplayState;Mode:TCameraMode;First:Boolean;
  Serial:Cardinal;Track:TSimCameraTrack;BeforeCut,AfterCut,ReplayFrame:TSimCameraFrame;
procedure Reset;
begin
  Camera.Enabled:=False;Probe.Ready:=True;Probe.Blocked:=False;Probe.BlockTravel:=False;
  Camera.Setup(View,Target,nil);Camera.GroundQuery:=@Probe.Ground;
  Camera.ClearPathQuery:=@Probe.ClearPath;Camera.RiderShotsEnabled:=True;
  Camera.AutoSwitch:=False;Camera.TargetSpeed:=7;
  Target.Translation:=Vector3(0,0,0);Target.Direction:=Vector3(0,0,1);
  Camera.Enabled:=True;Camera.ClearNearby;Camera.Update(0);
end;
begin
  Encounter(7,6,18,-1,2,0,ceOncoming);
  Encounter(9,5,10,1,1.7,0,ceOvertaken);
  Encounter(5,9,-10,1,1.7,0,ceOvertaking);
  Encounter(7,7,7,1,1.7,0,ceNone);
  Encounter(7,6,18,-1,12,0,ceNone);
  Encounter(7,6,18,-1,2,5,ceNone);
  Writeln('PASS: three encounter types, group exclusion, deck/lateral checks, per-rider cooldown');
  View:=TCastleViewport.Create(nil);Target:=TCastleTransform.Create(nil);
  Camera:=TCinematicCamera.Create;Probe:=TSceneProbe.Create;
  try
    if View.Camera=nil then begin View.Camera:=TCastleCamera.Create(View);View.Items.Add(View.Camera)end;
    for Phase:=0 to 2 do begin
      case Phase of 0:Fps:=30;1:Fps:=60;else Fps:=120 end;
      for Mode:=cmFrontQuarterLeft to cmFrontQuarterRight do begin
        Reset;Serial:=Camera.ShotSerial;Camera.ForceMode(Mode);
        Camera.Update(0);View.Camera.GetView(Prev,D,U);Offset:=Prev-Target.Translation;
        Check(Camera.ShotSerial=Serial+1,'close shot must create one recorded cut');
        Check(Offset.Z>2.5,'front shot must cut ahead immediately, without an orbit');
        for I:=1 to Fps*2 do begin
          Target.Translation:=Target.Translation+Vector3(0,0,7/Fps);
          Camera.Update(1/Fps);View.Camera.GetView(P,D,U);
          Near((P-Target.Translation-Offset).Length,0,0.002,'front composition drifts after cut');
          Near(P.Z-Prev.Z,7/Fps,0.002,'close camera follows from the first frame');
          Check(Camera.ShotSerial=Serial+1,'following generated repeated cuts');
          Prev:=P;
        end;
        P:=P-Target.Translation;
        Check((P.Z>2.5)and(Abs(P.X)>1.8)and(P.Length<6),'not a close front three-quarter shot');
        if Mode=cmFrontQuarterLeft then Check(P.X>0,'left view has wrong side')
        else Check(P.X<0,'right view has wrong side');
      end;
      Reset;Camera.ForceMode(cmFrontQuarterLeft);
      for I:=1 to Fps div 3 do begin
        Target.Translation:=Target.Translation+Vector3(0,0,7/Fps);Camera.Update(1/Fps);
      end;
      Saved:=Camera.CaptureReplay;Camera.Update(1/Fps);View.Camera.GetView(ExpectedP,ExpectedD,U);
      Camera.RestoreReplay(Saved);Camera.Update(1/Fps);View.Camera.GetView(P,D,U);
      Near((P-ExpectedP).Length,0,0.00001,'replay position');
      Near((D-ExpectedD).Length,0,0.00001,'replay direction');

      Reset;Rider:=Vector3(2,0,6);Camera.AddNearbyRider(42,Rider,Vector3(0,0,1),5,0);
      Camera.ForceMode(cmRiderPass);Check(Camera.EncounterRider=42,'manual preview did not select actual rider');
      Camera.Update(0);View.Camera.GetView(P,D,U);Offset:=P-Rider;
      Check(Offset.Z>2.5,'bot shot did not cut directly to the new subject');
      for I:=1 to Fps*2 do begin
        Target.Translation:=Target.Translation+Vector3(0,0,7/Fps);Rider:=Rider+Vector3(0,0,5/Fps);
        Camera.ClearNearby;Camera.AddNearbyRider(42,Rider,Vector3(0,0,1),5,0);
        View.Camera.GetView(Prev,D,U);Camera.Update(1/Fps);View.Camera.GetView(P,D,U);
        Near((P-Rider-Offset).Length,0,0.003,'bot framing has a residual transition');
        Near(P.Z-Prev.Z,5/Fps,0.003,'episode does not travel with selected rider');
      end;
      Check((P-Rider).Length<6,'episode failed to frame selected rider closely');
      Serial:=Camera.ShotSerial;
      BeforeCut:=Default(TSimCameraFrame);BeforeCut.Seconds:=1;
      BeforeCut.Position:=P;BeforeCut.Direction:=D;BeforeCut.Up:=U;
      BeforeCut.CinematicMode:=Ord(Camera.Mode);
      Camera.ClearNearby;Camera.Update(1/Fps);View.Camera.GetView(P,D,U);
      Check(Camera.Mode=cmMoto,'removed rider did not end episode');
      Check(P.Z<Target.Translation.Z-2,'bot-to-avatar return still flies through intermediate positions');
      Check(Camera.ShotSerial=Serial+1,'subject loss must record one cut');
      Offset:=P-Target.Translation;
      AfterCut:=BeforeCut;AfterCut.Seconds:=1+1/Fps;AfterCut.Position:=P;AfterCut.Direction:=D;
      AfterCut.CinematicMode:=Ord(Camera.Mode);AfterCut.CutBefore:=Camera.ShotSerial<>Serial;
      Track:=TSimCameraTrack.Create;
      try
        Track.Append(BeforeCut);Track.Append(AfterCut);
        Check(Track.Sample(1+0.5/Fps,ReplayFrame),'cut midpoint absent from replay');
        Near((ReplayFrame.Position-BeforeCut.Position).Length,0,0.00001,'slow replay invented a flight across the cut');
        Check(Track.Sample(AfterCut.Seconds,ReplayFrame),'new shot absent from replay');
        Near((ReplayFrame.Position-P).Length,0,0.00001,'replay cut does not reach destination');
      finally Track.Free end;
      for I:=1 to Fps*2 do begin
        Target.Translation:=Target.Translation+Vector3(0,0,7/Fps);Camera.Update(1/Fps);
        View.Camera.GetView(P,D,U);
        Near((P-Target.Translation-Offset).Length,0,0.003,'return composition keeps flying after the cut');
      end;
      Writeln('PASS direct cuts, continuous tracking, subject loss and slow replay at ',Fps,' fps');
    end;
    Reset;Probe.Ready:=False;Camera.ForceMode(cmFrontQuarterLeft);
    for I:=1 to 180 do Camera.Update(1/60);
    Check(Camera.Mode=cmMoto,'unloaded terrain accepted close shot');
    Reset;Probe.Blocked:=True;Camera.ForceMode(cmFrontQuarterRight);
    for I:=1 to 180 do Camera.Update(1/60);
    Check(Camera.Mode=cmMoto,'occluded subject accepted close shot');
    Reset;Probe.BlockTravel:=True;Camera.ForceMode(cmFrontQuarterLeft);Camera.Update(0);
    Check(Camera.Mode=cmFrontQuarterLeft,'a cut incorrectly requires a flyable path between cameras');
    Probe.Blocked:=True;Camera.Update(1/60);View.Camera.GetView(P,D,U);
    Check(Camera.Mode=cmMoto,'obstructed close shot did not return');
    Check(P.Z<Target.Translation.Z-2,'obstructed frame overwrote the safe return camera');
    Reset;Camera.RiderShotsEnabled:=False;Camera.ForceMode(cmFrontQuarterLeft);
    Check(Camera.Mode=cmMoto,'non-bicycle accepted rider shot');
    Reset;Camera.AutoSwitch:=True;First:=True;
    { Let the opening shot settle, then drive an actual approaching subject. }
    for I:=1 to 300 do begin Target.Translation:=Vector3(0,0,I*7/60);Camera.Update(1/60)end;
    for I:=1 to 180 do begin
      Target.Translation:=Vector3(0,0,35+I*7/60);
      Rider:=Vector3(2,0,53-I*6/60);Camera.ClearNearby;
      Camera.AddNearbyRider(101,Rider,Vector3(0,0,-1),6,0);Camera.Update(1/60);
      if(Camera.Mode=cmRiderPass)and First then begin
        Check(Camera.EncounterKind=ceOncoming,'director lost encounter type');First:=False;
      end;
    end;
    Check(not First,'automatic director did not activate approaching rider');
    Writeln('PASS geometry/pending rejection, transport guard and automatic episode');
  finally Probe.Free;Camera.Free;Target.Free;View.Free end;
end.
