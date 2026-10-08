program FreeTravelTest;
{$mode objfpc}{$H+}
uses SysUtils, Math, GameTravel;

procedure Check(Value:Boolean;const Why:String);
begin if not Value then raise Exception.Create(Why) end;

function HoldPower(Fps:Integer;Seconds:Single):Single;
var I:Integer;
begin
  Result:=0;
  for I:=1 to Round(Fps*Seconds) do Result:=KeyboardPower(Result,1,1/Fps);
end;

function HoldDistance(Fps:Integer;Seconds:Single):Double;
var I:Integer;Held:THeldMovement;
begin
  Held:=Default(THeldMovement);Result:=0;
  for I:=1 to Round(Fps*Seconds) do
    Result:=Result+HeldMovementSpeed(Held,1,1/Fps,3,280,10)/Fps;
end;

var Fps,I:Integer;Mode:TTravelMode;Rejected:Boolean;Held:THeldMovement;V:Single;
begin
  for Fps in [15,30,60,144,240] do begin
    Check(Abs(HoldPower(Fps,1)-250)<0.01,'Fast ramp at '+IntToStr(Fps));
    Check(Abs(HoldPower(Fps,3)-370)<0.03,'Continuous ramp at '+IntToStr(Fps));
    Check(Abs(HoldDistance(Fps,12)-1975)<0.01,'Flight distance independent of FPS at '+IntToStr(Fps));
  end;
  Held:=Default(THeldMovement);
  V:=HeldMovementSpeed(Held,1,0.2,3,280,10);
  Check((V>=3)and(V<3.2),'Fine initial flight speed');
  for I:=1 to 300 do V:=HeldMovementSpeed(Held,1,1/30,3,280,10);
  Check(Abs(V-280)<0.01,'Flight reaches maximum');
  V:=HeldMovementSpeed(Held,-1,0.2,3,280,10);
  Check((V<=-3)and(V>-3.2),'Reversal starts slowly');
  Check(HeldMovementSpeed(Held,0,0.1,3,280,10)=0,'Release stops immediately');
  V:=HeldMovementSpeed(Held,1,0.2,3,280,10);
  Check(V<3.2,'Next press starts slowly');
  Held:=Default(THeldMovement);
  for I:=1 to 200 do V:=HeldMovementSpeed(Held,1,1/30,1.4,5.5,6);
  Check(Abs(V-5.5)<0.001,'Automatic walking acceleration reaches run');
  Check(Abs(KeyboardPower(240,1,0.1)-253.6)<0.01,'Crossing 250 W');
  Check(KeyboardPower(20,-1,0.1)=0,'Braking cannot give negative power');
  Check(KeyboardPower(999,1,0.1)=1000,'Maximum power');
  Check(KeyboardPower(190,0,0.1)=190,'Released key holds effort');
  Check(KeyboardPower(190,1,0)=190,'Zero delta');
  Check(KeyboardPower(190,1,-1)=190,'Negative delta');
  for Mode:=Low(Mode) to High(Mode) do begin
    Rejected:=False;
    try Check(ParseTravel(TravelIds[Mode])=Mode,'Transport identity')
    except on E:EArgumentException do Rejected:=True end;
    Check(Rejected<>TravelAvailable(Mode),'Disabled transport rejected');
  end;
  Rejected:=False;
  try ParseTravel('unknown') except on E:EArgumentException do Rejected:=True end;
  Check(Rejected,'Unknown transport rejected');
  WriteLn('Free travel controls: PASS');
end.
