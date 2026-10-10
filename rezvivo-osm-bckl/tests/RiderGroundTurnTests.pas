program RiderGroundTurnTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,RiderGroundTurn;
var S:TGroundTurnState;I,J,N:Integer;Yaw,Delta:Double;

procedure Check(V:Boolean;const Why:string);
begin Inc(N);if not V then raise Exception.Create(Why) end;

function TurnFor(Fps:Integer;Steer:Single):Double;
var K,F:Integer;Prev:TGroundTurnState;
begin
  S:=Default(TGroundTurnState);Result:=0;
  for K:=1 to Fps*5 do begin
    Prev:=S;AdvanceGroundTurn(S,1/Fps,Steer,0,0,True);
    Result:=Result+S.Frame.YawDelta;
    if K/Fps<1.10 then Check(Abs(S.Frame.YawDelta)<1e-6,'Must stand and grip before turning');
    Check((S.Frame.FootLift[0]<1e-6)or(S.Frame.FootLift[1]<1e-6),'Always retain a planted foot');
    if Abs(S.Frame.YawDelta)>1e-6 then Check(S.Frame.BikeLift>0.06,'No turning tyres on the ground');
    for F:=0 to 1 do
      if Prev.Stepping and S.Stepping and(Prev.SwingFoot=S.SwingFoot)and(F<>S.SwingFoot)then
        Check(Abs(Prev.FootYaw[F]-S.FootYaw[F])<1e-7,'Planted foot must not slide');
  end;
end;

begin
  N:=0;Yaw:=TurnFor(60,1);Check(Yaw>2,'Turning at zero speed');
  Delta:=TurnFor(60,-1);Check(Abs(Yaw+Delta)<1e-5,'Symmetric left and right');
  for I in [30,120,240] do begin
    Delta:=TurnFor(I,1);Check(Abs(Yaw-Delta)<0.04,'Frame-rate-independent turn angle');
  end;
  for I:=1 to 240 do begin
    AdvanceGroundTurn(S,1/60,-1,0,0,True);
    for J:=0 to 1 do Check(Abs(S.Frame.FootAngle[J])<0.85,'Reversal must not cross the legs');
  end;
  for I:=1 to 300 do AdvanceGroundTurn(S,1/60,0,0,180,True);
  Check(S.Stage=gtsIdle,'Power must end turning and set down the bike');
  Check(S.Frame.BikeLift=0,'No residual lift after departure');
  AdvanceGroundTurn(S,0.1,1,4,0,True);
  Check(S.Stage=gtsIdle,'Moving bicycle must use normal steering');
  AdvanceGroundTurn(S,0.1,1,0,100,True);
  Check(S.Stage=gtsIdle,'Pedalling must not start a ground turn');
  AdvanceGroundTurn(S,0.1,1,0,0,True);
  Check(S.Stage=gtsPrepare,'Stopped bicycle can start another turn');
  AdvanceGroundTurn(S,0.1,1,0,0,False);
  Check((S.Stage=gtsIdle)and not S.Frame.Active,'Transport change resets turn');
  WriteLn('PASS: ',N,' ground-turn support and transition checks');
end.
