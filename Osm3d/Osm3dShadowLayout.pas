unit Osm3dShadowLayout;

{$mode objfpc}{$H+}

interface

uses CastleVectors;

type
  TShadowReceiverZone = record
    Focus: TVector3;
    HalfExtent, ViewDepth: Single;
    X, Y: Single; { texel-snapped light-space centre }
  end;
  TShadowReceiverLayout = record
    Zones: array[0..3] of TShadowReceiverZone;
    Side, Up, Direction: TVector3;
    MinX, MaxX, MinY, MaxY, MinDepth, MaxDepth: Single;
    CacheFocus: TVector3;
    CacheHalfExtent, ViewDistance: Single;
  end;

{ No scene queries, allocations or readbacks. Zone zero belongs to the avatar
  when present; the other three cover progressively longer camera frusta. }
procedure BuildShadowReceiverLayout(const Camera, Direction, FieldOfView,
  ReferencePoint, Sun: TVector3; const AvatarReceiver: Boolean;
  const WorldDistance: Single; const TileSize: Integer;
  out Layout: TShadowReceiverLayout);

implementation

uses Math;

procedure BuildShadowReceiverLayout(const Camera, Direction, FieldOfView,
  ReferencePoint, Sun: TVector3; const AvatarReceiver: Boolean;
  const WorldDistance: Single; const TileSize: Integer;
  out Layout: TShadowReceiverLayout);
const Fractions: array[0..3] of Single = (1/64, 1/16, 1/4, 1);
var
  D, Hint, Centre: TVector3;
  K2, FarDepth, Along, Radius, Height, TargetDepth, Distance, Step: Double;
  X, Y, Depth, H: Double;
  I: Integer;
begin
  Layout := Default(TShadowReceiverLayout);
  D := Direction.Normalize;
  Layout.Direction := Sun.Normalize;
  Hint := Vector3(0,1,0);
  if Abs(Layout.Direction.Y)>0.99 then Hint:=Vector3(0,0,1);
  Layout.Side := TVector3.CrossProduct(Layout.Direction,Hint).Normalize;
  Layout.Up := TVector3.CrossProduct(Layout.Side,Layout.Direction);
  Distance := EnsureRange(WorldDistance,60,160);
  Height := Max(0,Camera.Y-ReferencePoint.Y);
  TargetDepth := Max(Height,TVector3.DotProduct(ReferencePoint-Camera,D));
  if D.Y < -0.25 then TargetDepth := Max(TargetDepth,Height/-D.Y);
  Layout.ViewDistance := Max(Distance*1.25,TargetDepth*1.25+Distance*0.25);
  K2 := Sqr(Tan(EnsureRange(FieldOfView.X,0.05,3.0)*0.5)) +
        Sqr(Tan(EnsureRange(FieldOfView.Y,0.05,3.0)*0.5));
  Layout.MinX:=1e30; Layout.MinY:=1e30; Layout.MinDepth:=1e30;
  Layout.MaxX:=-1e30; Layout.MaxY:=-1e30; Layout.MaxDepth:=-1e30;
  for I:=0 to 3 do
  begin
    if (I=0) and AvatarReceiver then
    begin
      Centre:=ReferencePoint;
      H:=4;
      FarDepth:=0;
    end else begin
      FarDepth:=Layout.ViewDistance*Fractions[I];
      { Rotation-invariant sphere enclosing the complete truncated frustum,
        including the camera apex. Unlike a tight XY box it does not resize
        with each yaw/roll and make the shadow texels swim. }
      Along:=Min(FarDepth,FarDepth*(1+K2)*0.5);
      Radius:=Sqrt(Sqr(FarDepth-Along)+Sqr(FarDepth)*K2);
      Centre:=Camera+D*Along;
      { All visible corners lie inside the blend band, also after snapping. }
      H:=Ceil(Max(4,Radius/0.82+0.1)*4)*0.25;
    end;
    Step:=2*H/Max(1,TileSize);
    X:=Round((Double(Layout.Side.X)*Centre.X+Double(Layout.Side.Y)*Centre.Y+
      Double(Layout.Side.Z)*Centre.Z)/Step)*Step;
    Y:=Round((Double(Layout.Up.X)*Centre.X+Double(Layout.Up.Y)*Centre.Y+
      Double(Layout.Up.Z)*Centre.Z)/Step)*Step;
    Depth:=TVector3.DotProduct(Layout.Direction,Centre);
    Layout.Zones[I].Focus:=Centre;
    Layout.Zones[I].HalfExtent:=H;
    Layout.Zones[I].ViewDepth:=FarDepth;
    Layout.Zones[I].X:=X; Layout.Zones[I].Y:=Y;
    Layout.MinX:=Min(Layout.MinX,X-H); Layout.MaxX:=Max(Layout.MaxX,X+H);
    Layout.MinY:=Min(Layout.MinY,Y-H); Layout.MaxY:=Max(Layout.MaxY,Y+H);
    Layout.MinDepth:=Min(Layout.MinDepth,Depth-H-2);
    Layout.MaxDepth:=Max(Layout.MaxDepth,Depth+H+2);
  end;
  Layout.CacheHalfExtent:=Max(Layout.MaxX-Layout.MinX,Layout.MaxY-Layout.MinY)*0.5;
  Layout.CacheFocus:=Layout.Side*((Layout.MinX+Layout.MaxX)*0.5)+
    Layout.Up*((Layout.MinY+Layout.MaxY)*0.5)+
    Layout.Direction*((Layout.MinDepth+Layout.MaxDepth)*0.5);
end;

end.
