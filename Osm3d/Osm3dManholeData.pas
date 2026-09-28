unit Osm3dManholeData;
{$mode objfpc}{$H+}
interface
uses CastleVectors;
const
  MANHOLE_COUNT = 9;
  MANHOLE_IDS: array[0..8] of Integer = (10,9,5,2,8,3,16,15,13);
  { Full image footprint in metres, including any concrete surround.
    Keep the exact source image aspect ratio (08: 1024x548, 03: 1024x512,
    13: 1024x801). The round lid inside 16/15/13 occupies only 60/75/50%
    of the image width: size the surround so that the lid is about 0.72 m. }
  MANHOLE_SIZES: array[0..8] of TVector2 = (
    (X:0.85;Y:0.85),(X:0.85;Y:0.85),(X:0.8;Y:0.8),(X:0.85;Y:0.85),
    (X:1.4;Y:1.4*548/1024),(X:1.8;Y:0.9),
    (X:1.2;Y:1.2),(X:1.0;Y:1.0),(X:1.45;Y:1.45*801/1024));
type
  { Cached placement only: no copied ground mesh, texture or per-frame query. }
  TManhole = record
    Position, Normal: TVector3;
    Rotation: Single;
    Kind: Integer;
  end;
  TManholeArray = array of TManhole;
procedure ManholeAxes(const M:TManhole; out U,V:TVector3);
implementation
uses Math;
procedure ManholeAxes(const M:TManhole; out U,V:TVector3);
begin
  U:=Vector3(Cos(M.Rotation),0,Sin(M.Rotation));
  U.Y:=-(M.Normal.X*U.X+M.Normal.Z*U.Z)/Max(0.01,M.Normal.Y);
  U:=U.Normalize;
  V:=TVector3.CrossProduct(U,M.Normal).Normalize;
end;
end.
