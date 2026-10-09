unit AvatarGarmentPattern;
{$mode objfpc}{$H+}
interface
const OuterwearHipPower=2.6;
type
  TOuterwearPattern=record
    Slack,HemLength,Density:Single;
    LongHem:Boolean;
  end;
function OuterwearPattern(const Preset:string):TOuterwearPattern;
function GarmentSmooth(A,B,X:Single):Single;
procedure OuterwearSection(Slack,Y:Single;out RX,RZ,CZ:Single);
function OuterwearSectionExponent(Y:Single):Single;
procedure OuterwearBodySection(Y:Single;out RX,RZ,CZ:Single);
function OuterwearSectionGLSL:string;
procedure OuterwearOpening(T:Single;LongHem:Boolean;out Front,Back:Single);
implementation
uses Math;
const
  SectionCount=9;
  SectionY:array[0..SectionCount-1]of Single=(0.60,0.78,0.90,1.04,1.10,1.265,1.35,1.43,1.50);
  SectionX:array[0..SectionCount-1]of Single=(0.196,0.196,0.195,0.185,0.184,0.176,0.180,0.188,0.188);
  SectionZ:array[0..SectionCount-1]of Single=(0.122,0.132,0.139,0.129,0.124,0.136,0.132,0.109,0.096);
  SectionCentre:array[0..SectionCount-1]of Single=(-0.027,-0.027,-0.031,-0.025,-0.024,-0.032,-0.041,-0.045,-0.040);
function GarmentSmooth(A,B,X:Single):Single;
begin Result:=EnsureRange((X-A)/(B-A),0.0,1.0);Result:=Result*Result*(3-2*Result)end;
function OuterwearPattern(const Preset:string):TOuterwearPattern;
begin
  Result.Slack:=0.019;Result.HemLength:=0.20;Result.Density:=350;
  Result.LongHem:=False;
  if Preset='loose_jacket'then begin
    Result.Slack:=0.027;Result.HemLength:=0.25;Result.Density:=280;
  end else if Preset='coat'then begin
    Result.HemLength:=0.40;Result.Density:=460;Result.LongHem:=True;
  end else if Preset='raincoat'then begin
    { Hip-length zipped rain shell, as in the running/cycling references.
      The separately selectable coat retains the long, split skirt. }
    Result.Slack:=0.027;Result.HemLength:=0.32;Result.Density:=190;
  end;
end;
procedure OuterwearSection(Slack,Y:Single;out RX,RZ,CZ:Single);
var I:Integer;T,Ease:Single;
begin
  { A shoulder-supported shell, measured against the donor body. Front and
    back have different depth along the chest/waist; the skirt follows the
    hips, then falls straight. It is not a large cylinder with a flared rim.
    The same profile drives authored vertices, the cage and GPU lookup. }
  I:=0;while(I<SectionCount-2)and(Y>SectionY[I+1])do Inc(I);
  T:=GarmentSmooth(SectionY[I],SectionY[I+1],Y);Ease:=Slack-0.019;
  RX:=SectionX[I]*(1-T)+SectionX[I+1]*T+0.6*Ease;
  RZ:=SectionZ[I]*(1-T)+SectionZ[I+1]*T+0.7*Ease;
  CZ:=SectionCentre[I]*(1-T)+SectionCentre[I+1]*T;
end;
procedure OuterwearBodySection(Y:Single;out RX,RZ,CZ:Single);
begin
  OuterwearSection(0.019,Y,RX,RZ,CZ);
  RX:=RX-(0.027-0.009*GarmentSmooth(1.10,1.35,Y));
  RZ:=RZ-0.011;
end;
function OuterwearSectionExponent(Y:Single):Single;
begin
  { A hem spans two thighs. Rounded corners provide clearance there
    without increasing its front depth or lateral silhouette. }
  Result:=0.78+0.22*GarmentSmooth(0.94,1.10,Y);
end;
function OuterwearSectionGLSL:string;
var I:Integer;
  function Num(V:Single):string;
  begin Str(V:0:6,Result)end;
  function Point(J:Integer):string;
  begin Result:='vec3('+Num(SectionX[J])+','+Num(SectionZ[J])+','+Num(SectionCentre[J])+')'end;
begin
  Result:='vec3 acGarmentSection(float y,float slack){vec3 r;'+#10;
  for I:=0 to SectionCount-2 do begin
    if I>0 then Result:=Result+'else ';
    if I<SectionCount-2 then Result:=Result+'if(y<'+Num(SectionY[I+1])+')';
    Result:=Result+'r=mix('+Point(I)+','+Point(I+1)+',smoothstep('+Num(SectionY[I])+','+Num(SectionY[I+1])+',y));'+#10;
  end;
  Result:=Result+'return r+vec3(0.6,0.7,0.0)*(slack-0.019);}'+#10+
    'float acGarmentSectionExponent(float y){return 0.78+0.22*smoothstep(0.94,1.10,y);}'+#10;
end;
procedure OuterwearOpening(T:Single;LongHem:Boolean;out Front,Back:Single);
begin
  Front:=0;Back:=0;
  if LongHem then begin
    Front:=0.014+0.12*GarmentSmooth(0.05,0.6,T);
    Back:=0.10*GarmentSmooth(0.66,1,T);
  end;
end;
end.
