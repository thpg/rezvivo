unit Osm3dShadowSample;
{$mode objfpc}{$H+}
interface
uses CastleImages, CastleVectors;
{ CPU query of the existing packed ground masks; no texture readback. }
function GroundMaskCoverage(Buildings, Trees: TCastleImage; Res, BuildingBits,
  TreeBits: Integer; const Origin, Size, Point: TVector2): Single;
function PackedShadowValue(Img: TCastleImage; Res, Bits: Integer;
  Tree, Motion: Boolean; X, Y: Integer): Single;
implementation
uses Math, Osm3dWind;
function Smooth(T: Single): Single;
begin T := EnsureRange(T,0.0,1.0); Result := T*T*(3-2*T) end;
function Mix(A,B,T: Single): Single;
begin Result := A+(B-A)*T end;
function PackedShadowValue(Img: TCastleImage; Res, Bits: Integer;
  Tree, Motion: Boolean; X, Y: Integer): Single;
var Index, Offset, V, Mask: Integer;
begin
  Result := 0;
  if (Img=nil) or (Res<=0) or not (Bits in [1,2,4,8]) then Exit;
  X := EnsureRange(X,0,Res-1); Y := EnsureRange(Y,0,Res-1);
  Index := Y*Res+X;
  if Tree then
  begin
    if Bits>=8 then Offset := Index*2+Ord(Motion) else Offset := Index;
  end else Offset := Index div (8 div Bits);
  if (Offset<0) or (Offset>=Integer(Img.Width*Img.Height*Img.PixelSize)) then Exit;
  V := PByte(PtrUInt(Img.RawPixels)+PtrUInt(Offset))^;
  if Tree then
  begin
    if Bits>=8 then Result := V/255.0
    else if Motion then Result := (V shr 4)/15.0
    else Result := (V and 15)/15.0;
  end else
  begin
    Mask := (1 shl Bits)-1;
    Result := ((V shr ((Index mod (8 div Bits))*Bits)) and Mask)/Mask;
  end;
end;
function Filtered(Img: TCastleImage; Res, Bits: Integer; Tree: Boolean;
  X,Y: Single): Single;
var IX,IY: Integer; FX,FY: Single;
begin
  X := X-0.5; Y := Y-0.5; IX := Floor(X); IY := Floor(Y);
  FX := X-IX; FY := Y-IY;
  if Tree then begin FX := Smooth(FX); FY := Smooth(FY) end;
  Result := Mix(Mix(PackedShadowValue(Img,Res,Bits,Tree,False,IX,IY),
    PackedShadowValue(Img,Res,Bits,Tree,False,IX+1,IY),FX),
    Mix(PackedShadowValue(Img,Res,Bits,Tree,False,IX,IY+1),
    PackedShadowValue(Img,Res,Bits,Tree,False,IX+1,IY+1),FX),FY);
end;
function Hash(X,Y: Single): Single;
var H: Single;
begin
  X := X-Floor(X/4)*4; Y := Y-Floor(Y/4)*4;
  X := X*123.34; X := X-Floor(X); Y := Y*345.45; Y := Y-Floor(Y);
  H := X*(X+34.345)+Y*(Y+34.345); X := X+H; Y := Y+H;
  Result := X*Y; Result := Result-Floor(Result);
end;
function GroundMaskCoverage(Buildings, Trees: TCastleImage; Res, BuildingBits,
  TreeBits: Integer; const Origin, Size, Point: TVector2): Single;
var U,V,B,T,Moti,TimeNow,Base,Cell,FX,FY,Gust,Response,SX,SY: Single;
    D,G,GI: TVector2;
  function Noise(X,Y: Single): Single;
  begin Result := 0.5*Sin(X*1.7+Y*2.3)+0.5*Sin(X*3.1-Y*1.3) end;
begin
  Result := 0;
  if (Size.X<=0) or (Size.Y<=0) or (Res<=0) then Exit;
  U := (Point.X-Origin.X)/Size.X; V := (Point.Y-Origin.Y)/Size.Y;
  if (U<0) or (U>1) or (V<0) or (V>1) then Exit;
  B := Filtered(Buildings,Res,BuildingBits,False,U*Res,V*Res);
  { The visible building contour suppresses coverage below 0.12. }
  B := B*Smooth((B-0.08)/0.08);
  Moti := Sqrt(PackedShadowValue(Trees,Res,TreeBits,True,True,Floor(U*Res),Floor(V*Res)));
  if Moti>0 then
  begin
    { Match SHADOW_MASK_FS tree displacement and WIND_GLSL. Coordinates
      use the session frame, matching rendered ground vertices/vSMPos. }
    D := GlobalWind.Direction;
    if D.Length>1e-5 then D := D.Normalize else D := Vector2(1,0);
    TimeNow := WindNow; Base := WindCurrentBaseSpeed;
    Cell := Max(GlobalWind.RepeatLength/4,0.001);
    G := (Point-D*(Base*TimeNow))/Cell; GI := Vector2(Floor(G.X),Floor(G.Y));
    FX := Smooth(G.X-GI.X); FY := Smooth(G.Y-GI.Y);
    Gust := Mix(Mix(Hash(GI.X,GI.Y),Hash(GI.X+1,GI.Y),FX),
      Mix(Hash(GI.X,GI.Y+1),Hash(GI.X+1,GI.Y+1),FX),FY);
    Response := Min(Power(Max(Base+Mix(GlobalWind.GustSpeedMin,
      GlobalWind.GustSpeedMax,Gust),0)/10,1.3),2.5)*Moti;
    SX := (Noise(Point.X*0.3+TimeNow*1.7,Point.Y*0.3+TimeNow*1.1)*0.6+D.X*1.5)*Response;
    SY := (Noise(Point.X*0.3-TimeNow*1.3,Point.Y*0.3+TimeNow*1.9)*0.6+D.Y*1.5)*Response;
    U := U+SX/Size.X; V := V+SY/Size.Y;
  end;
  T := Filtered(Trees,Res,TreeBits,True,U*Res,V*Res);
  Result := EnsureRange(Max(B,T),0.0,1.0);
end;
end.
