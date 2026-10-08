program GaitDynamicsTest;
{$mode objfpc}{$H+}
uses SysUtils, Math, AvatarGait, TripoRig;
type TTrace=array[0..239,0..3]of Double;
var R:TTripoRig;G:TGaitFrame;S:TGaitDynamicsState;Reference,Trace:TTrace;
  Trial,I,J,Fps,Count,K:Integer;Speed,Rate,Peak,WalkPeak,RunPeak,SoftPeak,Error,StartEnergy,Energy:Double;
  Composition:Single;
const Rates:array[0..3]of Integer=(30,60,120,240);
procedure Require(OK:Boolean;const Msg:string);
begin if not OK then raise Exception.Create(Msg)end;
function EnergyOf(const D:TGaitDynamicsState):Double;
var N:Integer;
begin Result:=0;for N:=0 to 3 do Result:=Result+Sqr(D.Frame.Tissue[N])+Sqr(D.Velocity[N])/1000 end;
begin
  R:=TTripoRig.Create;
  try
    Require(R.LoadFromFile(ParamStr(1)),'Cannot load rig');
    WalkPeak:=0;RunPeak:=0;SoftPeak:=0;
    for Trial:=0 to 5 do begin
      Fps:=Rates[EnsureRange(Trial-2,0,3)];Speed:=4.5;Composition:=0.15;
      if Trial=0 then Speed:=1.4;
      if Trial=1 then Composition:=0.9;
      S:=Default(TGaitDynamicsState);Peak:=0;Count:=0;
      Rate:=GaitFrequency(Speed,AvatarGaitScale(R),Speed>2.5);
      for I:=0 to Fps*8 do begin
        PoseAvatarGait(R,Frac(I/Fps*Rate),Speed,Speed>2.5,G);
        AdvanceGaitDynamics(S,G,0.9,Composition,1/Fps);
        if I>=Fps*4 then for J:=0 to 3 do Peak:=Max(Peak,Abs(S.Frame.Tissue[J]));
        if(I>=Fps*4)and(I<Fps*8)and(I mod(Fps div 30)=0)then begin
          for J:=0 to 3 do Trace[Count,J]:=S.Frame.Tissue[J];Inc(Count);
        end;
        Require((S.Frame.SeatLoad[0]=0)and(S.Frame.SeatLoad[1]=0),'On-foot saddle load');
        for J:=0 to 3 do Require(not IsNan(S.Frame.Tissue[J])and(Abs(S.Frame.Tissue[J])<0.012*G.Scale),'Unstable tissue');
        for J:=0 to 7 do Require((S.Frame.Muscle[J]>=0)and(S.Frame.Muscle[J]<=1),'Muscle activation range');
      end;
      WriteLn('speed=',Speed:0:1,' composition=',Composition:0:2,' fps=',Fps,' peak=',Peak*1000:0:3,' mm');
      if Trial=0 then WalkPeak:=Peak;
      if Trial=1 then RunPeak:=Peak;
      if Trial=2 then begin SoftPeak:=Peak;Reference:=Trace end;
      if Trial>2 then begin
        Error:=0;for I:=0 to Count-1 do for J:=0 to 3 do Error:=Max(Error,Abs(Trace[I,J]-Reference[I,J]));
        WriteLn('  frame-rate error=',Error*1000:0:3,' mm');
        Require(Error<0.0005,'Frame-rate-dependent dynamics');
      end;
      StartEnergy:=EnergyOf(S);
      G.Amount:=0;G.Run:=0;
      for K:=1 to Fps*3 do AdvanceGaitDynamics(S,G,0,Composition,1/Fps);
      Energy:=EnergyOf(S);Require(Energy<StartEnergy*0.0001,'Tissue does not settle after stopping');
    end;
    Require(SoftPeak>WalkPeak*1.5,'Running landing has no stronger tissue response');
    Require(SoftPeak>RunPeak*1.3,'Body composition has no meaningful effect');
    WriteLn('PASS: landing response, body composition, damping, 30..240 FPS, no saddle contact.');
  finally R.Free end;
end.
