unit GameGlobeMath;
{$mode objfpc}{$H+}{$modeswitch advancedrecords}
interface
uses Math, Osm3dGeoMath;
type
  TGlobeVector=record X,Y,Z:Double;end;
  TGlobeTiles=array of TTileXY;
  TGlobeProjection=record
    Center:TLatLon;
    Altitude,Width,Height,Focal:Double;
    procedure Setup(const P:TLatLon;AAltitude,AWidth,AHeight:Double);
    function Local(const P:TLatLon):TGlobeVector;
    function Project(const P:TLatLon;out X,Y:Double):Boolean;
    function Pick(X,Y:Double;out P:TLatLon):Boolean;
    function NominalZoom:Double;
    function AltitudeForZoom(Z:Double):Double;
    function TileVisible(const T:TTileXY):Boolean;
    function SphereVisible(const V:TGlobeVector;Radius:Double):Boolean;
    function PoleVisible(Sign:Integer):Boolean;
    function Tiles:TGlobeTiles;
    function Bounds:TLatLonBox;
  end;
const GLOBE_FOV=40.0;GLOBE_MAX_ALTITUDE=3.0;GLOBE_MIN_ALTITUDE=0.000002;
function GlobeWrapLon(Lon:Double):Double;
function GlobeTilePoint(X,Y:Double;Z:Integer):TLatLon;
implementation
function GlobeWrapLon(Lon:Double):Double;
begin Result:=Lon-360*Floor((Lon+180)/360);end;
function GlobeTilePoint(X,Y:Double;Z:Integer):TLatLon;
begin Result:=TLatLon.Make(ArcTan(Sinh(Pi*(1-2*Y/(Int64(1)shl Z))))*180/Pi,X/(Int64(1)shl Z)*360-180);end;
procedure TGlobeProjection.Setup(const P:TLatLon;AAltitude,AWidth,AHeight:Double);
begin
  Center:=TLatLon.Make(EnsureRange(P.Lat,-89.9999,89.9999),GlobeWrapLon(P.Lon));
  Altitude:=EnsureRange(AAltitude,GLOBE_MIN_ALTITUDE,GLOBE_MAX_ALTITUDE);
  Width:=Max(1,AWidth);Height:=Max(1,AHeight);Focal:=Height/(2*Tan(GLOBE_FOV*Pi/360));
end;
function TGlobeProjection.Local(const P:TLatLon):TGlobeVector;
var A,C,D,L,Q:Double;
begin
  A:=P.Lat*Pi/180;C:=Center.Lat*Pi/180;D:=(P.Lat-Center.Lat)*Pi/180;
  L:=GlobeWrapLon(P.Lon-Center.Lon)*Pi/180;Q:=2*Sqr(Sin(L/2));
  Result.X:=Cos(A)*Sin(L);
  Result.Y:=Sin(D)+Sin(C)*Cos(A)*Q;
  { Stable sagitta. Subtracting two Earth-sized positions loses street detail. }
  Result.Z:=-2*Sqr(Sin(D/2))-Cos(C)*Cos(A)*Q;
end;
function TGlobeProjection.Project(const P:TLatLon;out X,Y:Double):Boolean;
var V:TGlobeVector;D:Double;
begin
  V:=Local(P);D:=Altitude-V.Z;
  Result:=(V.Z>=-Altitude/(1+Altitude))and(D>0);
  if not Result then begin X:=-1E20;Y:=-1E20;Exit;end;
  X:=Width/2+Focal*V.X/D;Y:=Height/2+Focal*V.Y/D;
end;
function TGlobeProjection.Pick(X,Y:Double;out P:TLatLon):Boolean;
var U,V,A,B,D,T,NX,NY,NZ,C,S,E:Double;
begin
  U:=(X-Width/2)/Focal;V:=(Y-Height/2)/Focal;
  A:=Altitude*(Altitude+2);B:=Altitude+1;D:=1-(U*U+V*V)*A;
  Result:=D>=0;if not Result then begin P:=Center;Exit;end;
  T:=A/(B+Sqrt(Max(0,D)));NX:=U*T;NY:=V*T;NZ:=B-T;
  C:=Cos(Center.Lat*Pi/180);S:=Sin(Center.Lat*Pi/180);E:=C*NZ-S*NY;
  P:=TLatLon.Make(ArcTan2(S*NZ+C*NY,Sqrt(E*E+NX*NX))*180/Pi,
    GlobeWrapLon(Center.Lon+ArcTan2(NX,E)*180/Pi));
end;
function TGlobeProjection.NominalZoom:Double;
begin Result:=Log2(2*Pi*Max(0.001,Cos(Center.Lat*Pi/180))*Focal/(256*Altitude));end;
function TGlobeProjection.AltitudeForZoom(Z:Double):Double;
begin Result:=EnsureRange(2*Pi*Max(0.001,Cos(Center.Lat*Pi/180))*Focal/(256*Power(2,Z)),GLOBE_MIN_ALTITUDE,GLOBE_MAX_ALTITUDE);end;
function TGlobeProjection.TileVisible(const T:TTileXY):Boolean;
var C,P:TLatLon;V:TGlobeVector;A,B,Radius:Double;I,J:Integer;
begin
  C:=GlobeTilePoint(T.X+0.5,T.Y+0.5,T.Zoom);V:=Local(C);Radius:=0;
  for J:=0 to 1 do for I:=0 to 1 do begin
    P:=GlobeTilePoint(T.X+I,T.Y+J,T.Zoom);A:=(P.Lat-C.Lat)*Pi/360;B:=(P.Lon-C.Lon)*Pi/360;
    Radius:=Max(Radius,2*Sqrt(Sqr(Sin(A))+Cos(P.Lat*Pi/180)*Cos(C.Lat*Pi/180)*Sqr(Sin(B))));
  end;
  Result:=SphereVisible(V,Radius);
end;
function TGlobeProjection.SphereVisible(const V:TGlobeVector;Radius:Double):Boolean;
var D,TX,TY:Double;
begin
  if V.Z+Radius< -Altitude/(1+Altitude) then Exit(False);
  D:=Altitude-V.Z;TX:=Width/(2*Focal);TY:=Height/(2*Focal);
  Result:=(Abs(V.X)-TX*D<=Radius*Sqrt(1+TX*TX))and
    (Abs(V.Y)-TY*D<=Radius*Sqrt(1+TY*TY));
end;
function TGlobeProjection.PoleVisible(Sign:Integer):Boolean;
begin Result:=SphereVisible(Local(TLatLon.Make(Sign*90,Center.Lon)),2*Sin((90-85.05112878)*Pi/360));end;
function TGlobeProjection.Tiles:TGlobeTiles;
var Count,X,Y:Integer;
  procedure Visit(const T:TTileXY);
  var P:TLatLon;V:TGlobeVector;Pixels:Double;I,J:Integer;
  begin
    if not TileVisible(T)then Exit;
    P:=GlobeTilePoint(T.X+0.5,T.Y+0.5,T.Zoom);V:=Local(P);
    Pixels:=Focal*2*Pi*Cos(P.Lat*Pi/180)/((Int64(1)shl T.Zoom)*Max(Altitude,Altitude-V.Z));
    if(T.Zoom<18)and(Pixels>320)then begin
      for J:=0 to 1 do for I:=0 to 1 do Visit(TTileXY.Make(T.X*2+I,T.Y*2+J,T.Zoom+1));
    end else begin
      if Count=Length(Result)then SetLength(Result,Max(64,Count*2));
      Result[Count]:=T;Inc(Count);
    end;
  end;
begin
  Result:=nil;Count:=0;
  for Y:=0 to 3 do for X:=0 to 3 do Visit(TTileXY.Make(X,Y,2));
  SetLength(Result,Count);
end;
function TGlobeProjection.Bounds:TLatLonBox;
var P:TLatLon;I,J:Integer;R,A,L,MinL,MaxL,MinA,MaxA:Double;
  procedure Include(const Q:TLatLon);
  begin
    L:=Center.Lon+GlobeWrapLon(Q.Lon-Center.Lon);
    MinL:=Min(MinL,L);MaxL:=Max(MaxL,L);MinA:=Min(MinA,Q.Lat);MaxA:=Max(MaxA,Q.Lat);
  end;
begin
  MinL:=Center.Lon;MaxL:=MinL;MinA:=Center.Lat;MaxA:=MinA;
  for J:=0 to 16 do for I:=0 to 16 do if Pick(I*Width/16,J*Height/16,P)then Include(P);
  R:=Focal/Sqrt(Altitude*(Altitude+2))*0.999999;
  for I:=0 to 127 do begin
    A:=I*2*Pi/128;
    if(Abs(R*Cos(A))<=Width/2)and(Abs(R*Sin(A))<=Height/2)and
      Pick(Width/2+R*Cos(A),Height/2+R*Sin(A),P)then Include(P);
  end;
  if Project(TLatLon.Make(90,Center.Lon),R,A)and(R>=0)and(R<=Width)and(A>=0)and(A<=Height)then begin MaxA:=90;MinL:=-180;MaxL:=180;end;
  if Project(TLatLon.Make(-90,Center.Lon),R,A)and(R>=0)and(R<=Width)and(A>=0)and(A<=Height)then begin MinA:=-90;MinL:=-180;MaxL:=180;end;
  Result:=TLatLonBox.Make(MinA,MinL,MaxA,MaxL);
end;
end.
