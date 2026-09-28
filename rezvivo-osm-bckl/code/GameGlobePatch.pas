unit GameGlobePatch;
{$mode objfpc}{$H+}
interface
uses CastleVectors, X3DNodes, Osm3dGeoMath, GameGlobeMath;
type
  TGlobePatch=class
  private
    FCoord:TCoordinateNode;FUV:TTextureCoordinateNode;FColor:TColorNode;
    FAppearance:TAppearanceNode;
    FTile:TTileXY;FSteps,FPolar:Integer;
    FPositioned:Boolean;FCenter:TLatLon;
    FNode:TSwitchNode;
    function GetExists:Boolean;
    procedure SetExists(Value:Boolean);
  public
    constructor CreatePatch(const T:TTileXY;Polar:Integer=0);
    destructor Destroy;override;
    procedure Position(const View:TGlobeProjection);
    procedure UseTexture(Texture:TPixelTextureNode;const Source:TTileXY);
    property Node:TSwitchNode read FNode;
    property Exists:Boolean read GetExists write SetExists;
  end;
implementation
uses Math;
constructor TGlobePatch.CreatePatch(const T:TTileXY;Polar:Integer);
var Shape:TShapeNode;Geo:TIndexedTriangleSetNode;Mat:TUnlitMaterialNode;
    Index:array of LongInt;Points:array of TVector3;UV:array of TVector2;X,Y,K,A:Integer;
begin
  inherited Create;FTile:=T;FPolar:=Polar;
  FSteps:=1 shl Max(1,7-T.Zoom);FSteps:=Min(FSteps,32);if Polar<>0 then FSteps:=64;
  FCoord:=TCoordinateNode.Create;FUV:=TTextureCoordinateNode.Create;FColor:=TColorNode.Create;
  { Hidden polar caps are still validated when the scene loads. }
  SetLength(Points,Sqr(FSteps+1));SetLength(UV,Length(Points));
  FCoord.SetPoint(Points);FColor.SetColor(Points);FUV.SetPoint(UV);
  Geo:=TIndexedTriangleSetNode.Create;Geo.Coord:=FCoord;Geo.TexCoord:=FUV;Geo.Color:=FColor;
  Geo.Solid:=True;Geo.ColorPerVertex:=True;
  SetLength(Index,FSteps*FSteps*6);K:=0;
  for Y:=0 to FSteps-1 do for X:=0 to FSteps-1 do begin
    A:=Y*(FSteps+1)+X;
    { Mercator rows run south; outward face is counterclockwise. }
    Index[K]:=A;Index[K+1]:=A+FSteps+1;Index[K+2]:=A+1;
    Index[K+3]:=A+1;Index[K+4]:=A+FSteps+1;Index[K+5]:=A+FSteps+2;Inc(K,6);
  end;
  Geo.SetIndex(Index);
  Mat:=TUnlitMaterialNode.Create;Mat.EmissiveColor:=Vector3(1,1,1);
  FAppearance:=TAppearanceNode.Create;FAppearance.Material:=Mat;
  Shape:=TShapeNode.Create;Shape.Appearance:=FAppearance;Shape.Geometry:=Geo;
  FNode:=TSwitchNode.Create;FNode.KeepExistingBegin;FNode.AddChildren(Shape);FNode.WhichChoice:=-1;
end;
destructor TGlobePatch.Destroy;
begin FNode.KeepExistingEnd;FNode.FreeIfUnused;inherited;end;
function TGlobePatch.GetExists:Boolean;
begin Result:=FNode.WhichChoice=0;end;
procedure TGlobePatch.SetExists(Value:Boolean);
begin if Value=GetExists then Exit;if Value then FNode.WhichChoice:=0 else FNode.WhichChoice:=-1;end;
procedure TGlobePatch.Position(const View:TGlobeProjection);
var P:array of TVector3;C:array of TVector3;I,J,K:Integer;Geo:TLatLon;V:TGlobeVector;Shade:Double;Base:TVector3;
begin
  { Texture replacement and camera altitude do not change this geometry. }
  if FPositioned and(FCenter.Lat=View.Center.Lat)and(FCenter.Lon=View.Center.Lon)then Exit;
  FPositioned:=True;FCenter:=View.Center;
  SetLength(P,Sqr(FSteps+1));SetLength(C,Length(P));K:=0;
  Base:=Vector3(1,1,1);
  if FPolar=1 then Base:=Vector3(180/255,210/255,221/255);
  if FPolar=-1 then Base:=Vector3(237/255,236/255,226/255);
  for J:=0 to FSteps do for I:=0 to FSteps do begin
    if FPolar=0 then Geo:=GlobeTilePoint(FTile.X+I/FSteps,FTile.Y+J/FSteps,FTile.Zoom)
    else if FPolar=1 then Geo:=TLatLon.Make(90-(90-85.05112878)*J/FSteps,-180+360*I/FSteps)
    else Geo:=TLatLon.Make(-85.05112878-(90-85.05112878)*J/FSteps,-180+360*I/FSteps);
    V:=View.Local(Geo);P[K]:=Vector3(V.X,V.Y,V.Z);
    Shade:=0.76+0.24*Sqrt(Max(0,V.Z+1));C[K]:=Base*Shade;Inc(K);
  end;
  FCoord.SetPoint(P);FColor.SetColor(C);
end;
procedure TGlobePatch.UseTexture(Texture:TPixelTextureNode;const Source:TTileXY);
var UV:array of TVector2;I,J,K,D:Integer;SX,SY:Double;
begin
  if FAppearance.Texture=Texture then Exit;
  FAppearance.Texture:=Texture;SetLength(UV,Sqr(FSteps+1));K:=0;
  D:=1 shl(FTile.Zoom-Source.Zoom);SX:=FTile.X-Source.X*D;SY:=FTile.Y-Source.Y*D;
  for J:=0 to FSteps do for I:=0 to FSteps do begin
    UV[K]:=Vector2((SX+I/FSteps)/D,1-(SY+J/FSteps)/D);Inc(K);
  end;
  FUV.SetPoint(UV);
end;
end.
