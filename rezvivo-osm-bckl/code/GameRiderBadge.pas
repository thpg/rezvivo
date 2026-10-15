unit GameRiderBadge;
{$mode objfpc}{$H+}
interface
uses Classes,CastleUIControls,CastleVectors,BikeParametric;
type
  TRiderBadge=class(TCastleUserInterface)
  public
    Color:TVector4;
    Bot:Boolean;
    Sex:Integer; { -1 unknown, 0 male, 1 female }
    constructor Create(AOwner:TComponent);override;
    procedure Render;override;
  end;
procedure RiderBadgeAppearance(Bike:TBikeInstance;out Color:TVector4;out Sex:Integer);
implementation
uses Math,CastleGLUtils,CastleColors,RiderTripo;
procedure RiderBadgeAppearance(Bike:TBikeInstance;out Color:TVector4;out Sex:Integer);
var C,D:TVector3;
begin
  Color:=Vector4(0.65,0.73,0.80,1);Sex:=-1;
  if Bike=nil then Exit;
  C:=Bike.RiderClothColor(csJersey);
  if not Bike.RiderClothColorActive(csJersey) then C:=ClothDyeNativeColor(csJersey);
  if Bike.TripoRider<>nil then C:=Bike.TripoRider.DisplayClothColor(csJersey);
  if(Bike.TripoRider<>nil)and(Bike.TripoRider.AppearanceAddon<>nil)then
    if Bike.TripoRider.AppearanceAddon.DisplayTopColor(D)then C:=D;
  Color:=Vector4(C.X,C.Y,C.Z,1);
  if Bike.TripoRider<>nil then Sex:=Ord(Bike.TripoRider.BodyParameters.Sex>=0.5);
end;
constructor TRiderBadge.Create(AOwner:TComponent);
begin inherited;Width:=24;Height:=30;Sex:=-1;Color:=White;CapturesEvents:=False end;
procedure TRiderBadge.Render;
var P:TVector2;S:Single;A:array[0..16]of TVector2;I:Integer;
  procedure Line(X0,Y0,X1,Y1:Single);
  begin DrawPrimitive2D(pmLines,[P+Vector2(X0,Y0)*S,P+Vector2(X1,Y1)*S],White) end;
  procedure Circle(X,Y,R:Single;C:TVector4);
  var K:Integer;
  begin
    for K:=0 to High(A)do A[K]:=P+Vector2(X+Cos(K*2*Pi/High(A))*R,Y+Sin(K*2*Pi/High(A))*R)*S;
    DrawPrimitive2D(pmTriangleFan,A,C);
  end;
begin
  inherited;P:=RenderRect.LeftBottom;S:=RenderRect.Width/24;
  { Outline preserves a dark kit's visibility; human mark is round, bot square. }
  if Bot then begin
    DrawPrimitive2D(pmTriangleFan,[P+Vector2(2,17)*S,P+Vector2(18,17)*S,
      P+Vector2(18,28)*S,P+Vector2(2,28)*S],White);
    DrawPrimitive2D(pmTriangleFan,[P+Vector2(3,18)*S,P+Vector2(17,18)*S,
      P+Vector2(17,27)*S,P+Vector2(3,27)*S],Color);
    Circle(7,23,1.2,Black);Circle(13,23,1.2,Black);Line(10,28,10,30);
  end else begin Circle(10,23,7.3,White);Circle(10,23,5.7,Color) end;
  if Sex<0 then Exit;
  for I:=0 to High(A)do A[I]:=P+Vector2(9+Cos(I*2*Pi/High(A))*3,9+Sin(I*2*Pi/High(A))*3)*S;
  DrawPrimitive2D(pmLineStrip,A,White);
  if Sex=0 then begin Line(11,11,16,16);Line(12,16,16,16);Line(16,12,16,16) end
  else begin Line(9,6,9,1);Line(6,3,12,3) end;
end;
end.
