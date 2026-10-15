unit GameCameraEncounters;
{$mode objfpc}{$H+}
interface
uses Math,CastleVectors;
type
  TCameraEncounterKind=(ceNone,ceOncoming,ceOvertaken,ceOvertaking);
  TCameraRider=record
    Id:Int64;
    Position,Direction:TVector3;
    Speed,Pitch:Single;
  end;
  TCameraEncounterTrack=record
    Id:Int64;
    SeenAt,ShotAt:Double;
    StableSeconds,Ahead,RelativeRate:Single;
    Position:TVector3;
    Used:Boolean;
  end;
  TCameraEncounterTracker=record
    Time:Double;
    Cooldown:Single;
    Tracks:array[0..31]of TCameraEncounterTrack;
  end;
function UpdateCameraEncounters(var State:TCameraEncounterTracker;
  const Riders:array of TCameraRider;Count:Integer;
  const Position,Direction:TVector3;Speed,Dt:Single;CanSelect:Boolean;
  out Kind:TCameraEncounterKind):Integer;
implementation
function UpdateCameraEncounters(var State:TCameraEncounterTracker;
  const Riders:array of TCameraRider;Count:Integer;
  const Position,Direction:TVector3;Speed,Dt:Single;CanSelect:Boolean;
  out Kind:TCameraEncounterKind):Integer;
var I,J,K,Oldest,SelectedTrack:Integer;Fwd,Side,Delta,RiderDir:TVector3;
  Gap,Lateral,Alignment,Rate,TimeToPass,Score,Best:Single;
  ThisKind:TCameraEncounterKind;
begin
  Result:=-1;Kind:=ceNone;
  if Dt<=0 then Exit;
  State.Time:=State.Time+Dt;State.Cooldown:=Max(0,State.Cooldown-Dt);
  Fwd:=Direction;Fwd.Y:=0;if Fwd.LengthSqr<0.01 then Exit;Fwd:=Fwd.Normalize;
  Side:=TVector3.CrossProduct(Fwd,Vector3(0,1,0));Best:=1e20;SelectedTrack:=-1;
  for I:=0 to Min(Count,Length(Riders))-1 do begin
    if Riders[I].Id=0 then Continue;
    K:=-1;Oldest:=0;
    for J:=0 to High(State.Tracks)do begin
      if State.Tracks[J].Id=Riders[I].Id then begin K:=J;Break end;
      if State.Tracks[J].SeenAt<State.Tracks[Oldest].SeenAt then Oldest:=J;
    end;
    if K<0 then begin
      K:=Oldest;State.Tracks[K]:=Default(TCameraEncounterTrack);
      State.Tracks[K].Id:=Riders[I].Id;State.Tracks[K].SeenAt:=-100;
    end;
    Delta:=Riders[I].Position-Position;Gap:=TVector3.DotProduct(Delta,Fwd);
    Lateral:=Abs(TVector3.DotProduct(Delta,Side));
    with State.Tracks[K]do begin
      if (State.Time-SeenAt>Max(0.5,Dt*2))or
        (Delta.Length>36)or
        ((Riders[I].Position-State.Tracks[K].Position).Length>Max(3,Dt*45))then begin
        StableSeconds:=0;RelativeRate:=0;
        { A reappearing rider must have left the scene for a while. Small
          culling gaps or repeated crossings cannot retrigger a close-up. }
        if (State.Time-SeenAt>15)and(State.Time-ShotAt>75)then Used:=False;
      end else begin
        StableSeconds:=StableSeconds+Dt;
        Rate:=(Gap-State.Tracks[K].Ahead)/Dt;
        RelativeRate:=RelativeRate+(Rate-RelativeRate)*(1-Exp(-6*Dt));
      end;
      State.Tracks[K].Ahead:=Gap;State.Tracks[K].Position:=Riders[I].Position;
      SeenAt:=State.Time;
      if not CanSelect or(State.Cooldown>0)or Used or(StableSeconds<0.35)or
        (Speed<0.8)or(Riders[I].Speed<0.5)or(Lateral>4.5)or
        (Abs(Delta.Y)>1.8)or(Abs(Gap)<1.5)or(Abs(Gap)>20)then Continue;
      RiderDir:=Riders[I].Direction;RiderDir.Y:=0;
      if RiderDir.LengthSqr<0.01 then Continue;RiderDir:=RiderDir.Normalize;
      Alignment:=TVector3.DotProduct(Fwd,RiderDir);ThisKind:=ceNone;
      if(Alignment< -0.5)and(Gap>0)and(RelativeRate< -1)then ThisKind:=ceOncoming
      else if Alignment>0.65 then begin
        if(Gap>0)and(RelativeRate< -0.65)then ThisKind:=ceOvertaken
        else if(Gap<0)and(RelativeRate>0.65)then ThisKind:=ceOvertaking;
      end;
      if ThisKind=ceNone then Continue;
      TimeToPass:=Abs(Gap/RelativeRate);
      if(TimeToPass<0.4)or(TimeToPass>2.8)then Continue;
      Score:=TimeToPass+Lateral*0.15;
      if Score<Best then begin Best:=Score;Result:=I;SelectedTrack:=K;Kind:=ThisKind end;
    end;
  end;
  if SelectedTrack>=0 then begin
    State.Tracks[SelectedTrack].Used:=True;
    State.Tracks[SelectedTrack].ShotAt:=State.Time;State.Cooldown:=20;
  end;
end;
end.
