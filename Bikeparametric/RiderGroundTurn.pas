unit RiderGroundTurn;

{$mode objfpc}{$H+}

{ One clock, owned by fixed-step physics. Rendering consumes the same support
  state; it must not advance another stepping cycle at the display frame rate. }
interface

type
  TGroundTurnStage = (gtsIdle, gtsPrepare, gtsTurning, gtsSettle, gtsLower);
  TGroundTurnFrame = record
    Active: Boolean;
    Blend, BikeLift, YawDelta, YawRate: Single;
    FootAngle, FootLift: array[0..1] of Single;
    WeightShift: Single;
  end;
  TGroundTurnState = record
    Stage: TGroundTurnStage;
    Time, Yaw, Rate: Double;
    FootYaw: array[0..1] of Double;
    StepTime, StepFrom, StepTo: Double;
    SwingFoot, NextFoot: Integer;
    Stepping: Boolean;
    Frame: TGroundTurnFrame;
  end;

procedure AdvanceGroundTurn(var S:TGroundTurnState;
  Dt, Steer, Speed, Power:Single; Enabled:Boolean);

implementation

uses Math;

const PrepareTime=1.15; StepDuration=0.38; LowerTime=1.10;

function Smooth(X:Double):Double;
begin X:=EnsureRange(X,0.0,1.0);Result:=X*X*(3-2*X) end;

procedure AdvanceGroundTurn(var S:TGroundTurnState;
  Dt, Steer, Speed, Power:Single; Enabled:Boolean);
var Want:Boolean; I:Integer; T,OldYaw,Target:Double;

  procedure BeginStep(Foot:Integer; Goal:Double);
  begin
    S.Stepping:=True;S.SwingFoot:=Foot;S.StepTime:=0;
    S.StepFrom:=S.FootYaw[Foot];S.StepTo:=Goal;
  end;

begin
  if not Enabled then begin S:=Default(TGroundTurnState);Exit end;
  if Dt<=0 then Exit;
  Dt:=Min(Dt,0.1);
  Want:=(Abs(Steer)>0.08)and(Abs(Speed)<0.15)and(Power<10);
  if S.Stage=gtsIdle then begin
    S.Frame:=Default(TGroundTurnFrame);
    if not Want then Exit;
    S:=Default(TGroundTurnState);S.Stage:=gtsPrepare;
    S.NextFoot:=Ord(Steer<0);
  end;
  OldYaw:=S.Yaw;S.Time:=S.Time+Dt;
  S.Frame:=Default(TGroundTurnFrame);S.Frame.Active:=True;
  case S.Stage of
    gtsPrepare:begin
      S.Frame.Blend:=Smooth(S.Time/0.75);
      S.Frame.BikeLift:=0.065*Smooth((S.Time-0.75)/0.40);
      if S.Time>=PrepareTime then begin
        S.Time:=0;
        if Want then S.Stage:=gtsTurning else S.Stage:=gtsSettle;
      end;
    end;
    gtsTurning,gtsSettle:begin
      S.Frame.Blend:=1;S.Frame.BikeLift:=0.065;
      if not Want then S.Stage:=gtsSettle;
      if Want and(S.Stage=gtsSettle)then S.Stage:=gtsTurning;
      Target:=0;if S.Stage=gtsTurning then Target:=EnsureRange(Steer,-1,1)*0.65;
      S.Rate:=S.Rate+EnsureRange(Target-S.Rate,-2.4*Dt,2.4*Dt);
      S.Yaw:=S.Yaw+S.Rate*Dt;
      if not S.Stepping then begin
        if Abs(S.Rate)>0.02 then begin
          BeginStep(S.NextFoot,S.Yaw+S.Rate*StepDuration);
          S.NextFoot:=1-S.NextFoot;
        end else if S.Stage=gtsSettle then begin
          if Abs(S.FootYaw[0]-S.Yaw)>0.002 then BeginStep(0,S.Yaw)
          else if Abs(S.FootYaw[1]-S.Yaw)>0.002 then BeginStep(1,S.Yaw)
          else begin S.Stage:=gtsLower;S.Time:=0 end;
        end;
      end;
      if S.Stepping then begin
        S.StepTime:=Min(StepDuration,S.StepTime+Dt);
        T:=S.StepTime/StepDuration;
        S.FootYaw[S.SwingFoot]:=S.StepFrom+(S.StepTo-S.StepFrom)*Smooth(T);
        S.Frame.FootLift[S.SwingFoot]:=0.055*Sqr(Sin(Pi*T));
        S.Frame.WeightShift:=(2*S.SwingFoot-1)*0.014*Sin(Pi*T);
        if S.StepTime>=StepDuration then S.Stepping:=False;
      end;
    end;
    gtsLower:begin
      S.Frame.BikeLift:=0.065*(1-Smooth(S.Time/0.35));
      S.Frame.Blend:=1-Smooth((S.Time-0.35)/0.75);
      if S.Time>=LowerTime then begin S:=Default(TGroundTurnState);Exit end;
    end;
    else ;
  end;
  S.Frame.YawDelta:=S.Yaw-OldYaw;S.Frame.YawRate:=S.Rate;
  for I:=0 to 1 do S.Frame.FootAngle[I]:=S.FootYaw[I]-S.Yaw;
end;

end.
