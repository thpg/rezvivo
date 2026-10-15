unit Osm3dMotionPrefetch;
{$mode objfpc}{$H+}{$modeswitch advancedrecords}

interface

uses CastleVectors;

type
  { Render-local observations, never physics integration. Sampling at 50 ms
    also avoids amplifying Single coordinate quantization at OSM origins. }
  TMotionPrefetch = record
  private
    FPosition, FDirection, FVelocity: TVector3;
    FTick: QWord;
    FViewKey: PtrUInt;
    FValid: Boolean;
  public
    procedure Reset;
    { True when pending preparation belongs to an obsolete view. }
    function Observe(const Position, ViewDirection: TVector3;
      Tick: QWord; ViewKey: PtrUInt): Boolean;
    function Offset(Seconds, Maximum: Single): TVector3;
    function CacheOffset(Radius, VisibleRadius, Reserve, Seconds: Single): TVector3;
    function Speed: Single;
  end;

{ Visible detail always wins over speculative work; equally distant hidden
  detail is prepared first in the predicted direction. }
function PrefetchPriority(const Position, Viewer, Predicted: TVector3;
  VisibleRadius: Single): Single;
function ShadowForwardExtension(const Motion: TMotionPrefetch;
  const ViewDirection: TVector3; WorldDistance, ViewHeight: Single;
  TileSize: Integer): Single;

implementation

uses Math;

procedure TMotionPrefetch.Reset;
begin Self:=Default(TMotionPrefetch);end;

function TMotionPrefetch.Observe(const Position, ViewDirection: TVector3;
  Tick: QWord; ViewKey: PtrUInt): Boolean;
var Delta, Raw, Direction: TVector3; Dt, Blend: Single;
begin
  Result:=False;
  Direction:=ViewDirection;
  if Direction.LengthSqr>0.0001 then Direction:=Direction.Normalize;
  if not FValid or (ViewKey<>FViewKey) or (Tick<FTick) or
    (Tick-FTick>1000) or
    ((Direction.LengthSqr>0.5) and (FDirection.LengthSqr>0.5) and
     (TVector3.DotProduct(Direction,FDirection)<0.5)) then
  begin
    Result:=FValid;FValid:=True;FPosition:=Position;FDirection:=Direction;
    FTick:=Tick;FViewKey:=ViewKey;FVelocity:=TVector3.Zero;Exit;
  end;
  if Tick-FTick<50 then Exit;
  Dt:=(Tick-FTick)*0.001;Delta:=Position-FPosition;
  FPosition:=Position;FTick:=Tick;FDirection:=Direction;
  { A teleport, camera cut or fast seek must not spend the next seconds
    building along a velocity that never belonged to the ride. }
  if Delta.Length>Max(12,Dt*80) then
  begin FVelocity:=TVector3.Zero;Exit(True);end;
  Raw:=Vector3(Delta.X/Dt,0,Delta.Z/Dt);
  if Raw.Length<0.15 then begin FVelocity:=TVector3.Zero;Exit;end;
  if TVector3.DotProduct(Raw,FVelocity)<0 then FVelocity:=TVector3.Zero;
  Blend:=1-Exp(-Dt/0.25);
  FVelocity:=FVelocity+(Raw-FVelocity)*Blend;
end;

function TMotionPrefetch.Speed: Single;
begin Result:=FVelocity.Length;end;

function TMotionPrefetch.Offset(Seconds, Maximum: Single): TVector3;
var Distance: Single;
begin
  Result:=FVelocity*Max(0,Seconds);Distance:=Result.Length;
  if Distance>Max(0,Maximum) then Result:=Result*(Max(0,Maximum)/Distance);
end;

function TMotionPrefetch.CacheOffset(Radius, VisibleRadius, Reserve,
  Seconds: Single): TVector3;
begin Result:=Offset(Seconds,Max(0,Radius-VisibleRadius-Reserve));end;

function PrefetchPriority(const Position, Viewer, Predicted: TVector3;
  VisibleRadius: Single): Single;
var Distance: Single;
begin
  Distance:=(Position-Viewer).Length;
  if Distance<=VisibleRadius then Exit(Distance);
  Result:=VisibleRadius+Max(0.01,(Position-Predicted).Length-VisibleRadius);
end;

function ShadowForwardExtension(const Motion: TMotionPrefetch;
  const ViewDirection: TVector3; WorldDistance, ViewHeight: Single;
  TileSize: Integer): Single;
var Direction, Ahead: TVector3; Alignment: Single;
begin
  Result:=0;
  { Keep the effective 60 m Universal/low preset and tiny shadow maps at
    their configured cost. Aerial views already fit a longer frustum. }
  if (WorldDistance<100) or (TileSize<512) or (Motion.Speed<0.15) then Exit;
  Direction:=Vector3(ViewDirection.X,0,ViewDirection.Z);
  if Direction.LengthSqr<0.01 then Exit;
  Ahead:=Motion.Offset(1,80);
  Alignment:=Max(0,TVector3.DotProduct(Direction.Normalize,Ahead.Normalize));
  Result:=Min(Motion.Speed*1.5,WorldDistance*0.20)*Alignment*
    EnsureRange(1-Max(0,ViewHeight-10)/Max(1,WorldDistance*0.5),0.0,1.0)*
    Min(1.0,TileSize/1024);
end;

end.
