program RiderAnthropometryParametersTest;
{$mode objfpc}{$H+}
uses SysUtils,Math,fpjson,RiderBodyParameters;
var P,Q:TRiderBodyParameters;J:TJSONObject;C:TRiderBodyCoefficients;I:Integer;
procedure Check(Condition:Boolean;const Reason:String);
begin if not Condition then raise Exception.Create(Reason)end;
begin
  P:=DefaultRiderBody;
  J:=TJSONObject.Create;
  try J.Add('version',1);J.Add('heightCm',178);Q:=ReadRiderBody(J,P);
  finally J.Free end;
  Check((Q.HeightCm=178)and(Q.PelvisWidth=0)and(Q.CalfSize=0),'old profile defaults');
  P.PelvisWidth:=0.17;P.ShoulderWidth:=-0.13;P.WaistSize:=0.19;
  P.ThighSize:=-0.16;P.CalfSize:=0.11;
  J:=WriteRiderBody(P);
  try Q:=ReadRiderBody(J,DefaultRiderBody);Check(SameRiderBody(P,Q),'new profile round trip');
  finally J.Free end;
  Q.CalfSize:=0;Check(not SameRiderBody(P,Q),'calf edit invalidates static shape');
  Q.PelvisWidth:=10;Q.ShoulderWidth:=-10;Q.WaistSize:=NaN;
  Q.ThighSize:=Infinity;Q.CalfSize:=-10;Q:=NormalizeRiderBody(Q);
  Check((Abs(Q.PelvisWidth-0.18)<1e-6)and(Abs(Q.ShoulderWidth+0.14)<1e-6),'width bounds');
  Check((Q.WaistSize=0)and(Q.ThighSize=0)and(Abs(Q.CalfSize+0.18)<1e-6),'invalid girths');
  RiderBodyCoefficients(P,C);
  Check((Abs(C[8]-0.85)<1e-6)and(Abs(C[9]+0.65)<1e-6),'width endpoint weights');
  RiderBodyCoefficients(DefaultRiderBody,C);
  for I:=5 to High(C)do Check(C[I]=0,'neutral old shape unchanged');
  Writeln('ANTHROPOMETRY_PARAMETERS_OK');
end.
