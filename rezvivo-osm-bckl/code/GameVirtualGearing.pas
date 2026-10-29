{ Virtual transmission, independent of sensor power and ride physics.
  Native ratio protocol: makinolo.com/blog/2024/10/20/zwift-trainer-protocol/
  Standard-control fallback: calculate crank load from cadence and gear ratio,
  then send target power; trainer response differs from native gearing.
  Never substitute a target or calculated watt value for measured power. }
unit GameVirtualGearing;
{$mode objfpc}{$H+}
interface
uses SysUtils;
const
  VirtualGearCount=24;
  DefaultVirtualGear=12;
  VirtualGearRatios:array[1..VirtualGearCount] of Single=(
    0.75,0.87,0.99,1.11,1.23,1.38,1.53,1.68,1.86,2.04,2.22,2.40,
    2.61,2.82,3.03,3.24,3.49,3.74,3.99,4.24,4.54,4.84,5.14,5.49);
type
  TGearingBackend=(gbOff,gbNative,gbFTMSPower,gbUnavailable);
  TGearingLoad=record
    VirtualSpeedMps,CrankTorqueNm,Watts:Single;
  end;
function VirtualGearRatio(Gear:Integer):Single;
function CalculateGearingLoad(Gear:Integer;CadenceRPM,GradePercent,WindMps,
  RiderKg,BikeKg,WheelCircumferenceM:Single):TGearingLoad;
function ZwiftTrainerHandshake:TBytes;
function ZwiftSimulationCommand(Grade,Wind,RiderKg,BikeKg,Ratio:Single):TBytes;
implementation
uses Math;
function VirtualGearRatio(Gear:Integer):Single;
begin Result:=VirtualGearRatios[EnsureRange(Gear,1,VirtualGearCount)] end;
function CalculateGearingLoad(Gear:Integer;CadenceRPM,GradePercent,WindMps,
  RiderKg,BikeKg,WheelCircumferenceM:Single):TGearingLoad;
var V,Air,Mass,Angle,Force,Omega:Double;
begin
  Result:=Default(TGearingLoad);
  if IsNan(CadenceRPM) or IsInfinite(CadenceRPM) or (CadenceRPM<1) then Exit;
  if IsNan(GradePercent) or IsInfinite(GradePercent) or
    IsNan(WindMps) or IsInfinite(WindMps) or
    IsNan(RiderKg) or IsInfinite(RiderKg) or
    IsNan(BikeKg) or IsInfinite(BikeKg) or
    IsNan(WheelCircumferenceM) or IsInfinite(WheelCircumferenceM) then Exit;
  Mass:=EnsureRange(RiderKg,20,250)+EnsureRange(BikeKg,3,50);
  V:=EnsureRange(CadenceRPM,0,220)/60*VirtualGearRatio(Gear)*EnsureRange(WheelCircumferenceM,1,3);
  Angle:=ArcTan(EnsureRange(GradePercent,-25,25)/100);
  Air:=V+EnsureRange(WindMps,-30,30);
  { Gravity + rolling + signed aerodynamic drag. An ordinary trainer cannot
    drive the cranks on descents; clamp negative demand to zero. At fixed
    cadence a higher ratio needs more torque. No measured-watts feedback. }
  Force:=Max(0,Mass*9.80665*(Sin(Angle)+0.004*Cos(Angle))+
    0.5*1.225*0.51*Air*Abs(Air));
  Result.VirtualSpeedMps:=V;
  Result.Watts:=Min(2500,Force*V);
  Omega:=CadenceRPM*2*Pi/60;
  Result.CrankTorqueNm:=Result.Watts/Omega;
end;
procedure VarInt(var B:TBytes;V:Cardinal);
var N:Integer;
begin
  repeat
    N:=Length(B);SetLength(B,N+1);B[N]:=V and $7F;V:=V shr 7;
    if V<>0 then B[N]:=B[N] or $80;
  until V=0;
end;
procedure UInt(var B:TBytes;Tag:Byte;V:Cardinal);
begin VarInt(B,Tag);VarInt(B,V) end;
procedure SInt(var B:TBytes;Tag:Byte;V:Integer);
var Z:Cardinal;
begin
  if V<0 then Z:=Cardinal(-Int64(V)*2-1) else Z:=Cardinal(V)*2;
  UInt(B,Tag,Z);
end;
procedure Nested(var B:TBytes;Tag:Byte;const Part:TBytes);
var N:Integer;
begin
  UInt(B,Tag,Length(Part));N:=Length(B);SetLength(B,N+Length(Part));
  if Length(Part)>0 then Move(Part[0],B[N],Length(Part));
end;
function ZwiftTrainerHandshake:TBytes;
begin Result:=TBytes.Create($52,$69,$64,$65,$4F,$6E,$01,$00) end;
function ZwiftSimulationCommand(Grade,Wind,RiderKg,BikeKg,Ratio:Single):TBytes;
var P:TBytes;
begin
  Result:=nil;
  if IsNan(Grade) or IsInfinite(Grade) or IsNan(Wind) or IsInfinite(Wind) or
    IsNan(RiderKg) or IsInfinite(RiderKg) or IsNan(BikeKg) or IsInfinite(BikeKg) or
    IsNan(Ratio) or IsInfinite(Ratio) then Exit;
  Result:=TBytes.Create($04);P:=nil;
  SInt(P,$08,Round(EnsureRange(Wind,-30,30)*100));
  SInt(P,$10,Round(EnsureRange(Grade,-25,25)*100));
  UInt(P,$18,5100);UInt(P,$20,400);Nested(Result,$22,P);
  P:=nil;UInt(P,$10,Round(EnsureRange(Ratio,0,6)*10000));
  UInt(P,$20,Round(EnsureRange(BikeKg,3,50)*100));
  UInt(P,$28,Round(EnsureRange(RiderKg,20,250)*100));Nested(Result,$2A,P);
end;
end.
