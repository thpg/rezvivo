unit GameWorkoutGateGuide;
{$mode objfpc}{$H+}
interface
uses CastleVectors, CastleColors, GamePath, GameWorkoutPlayer;
const WorkoutGateLeadSeconds=15.0;
type
  TWorkoutGatePose=record
    Visible:Boolean;
    Position,Forward:TVector3;
    Width,Opacity,FilmOpacity,Remaining,DistanceAhead:Single;
    Color:TCastleColor;
    NextIndex:Integer;
  end;
  { No rendering or physics mutation: the same guide is exercised by route tests. }
  TWorkoutGateGuide=class
  private
    FUpcoming,FPassed:TWorkoutGatePose;
    FHaveSample,FWasRunning:Boolean;
    FRevision:QWord;
    FRoute:TGamePath;
    FLastIndex:Integer;
    FLastElapsed:Double;
    FLastPosition:TVector3;
    FLastSpeed,FSpeed,FAcceleration,FPassedAge,FVisibleAge:Single;
    FCrossings:Integer;
    FCrossingPoint:TVector3;
    FCrossingElapsed:Double;
    FCrossingPlaneError:Single;
  public
    procedure Reset;
    procedure Update(Player:TWorkoutPlayer;Route:TGamePath;
      const RiderPosition,RiderForward:TVector3;Speed,Seconds:Single;WorldReady:Boolean);
    property Upcoming:TWorkoutGatePose read FUpcoming;
    property Passed:TWorkoutGatePose read FPassed;
    property Crossings:Integer read FCrossings;
    property CrossingPoint:TVector3 read FCrossingPoint;
    property CrossingElapsed:Double read FCrossingElapsed;
    property CrossingPlaneError:Single read FCrossingPlaneError;
  end;

function WorkoutGatePlacement(Route:TGamePath;const RiderPosition,RiderForward:TVector3;
  const DistanceAhead:Single):TWorkoutGatePose;

implementation
uses Math,GameWorkoutColors;

function FlatDirection(const V,Fallback:TVector3):TVector3;
var L:Single;
begin
  L:=Sqrt(Sqr(V.X)+Sqr(V.Z));
  if L>0.0001 then Result:=Vector3(V.X/L,0,V.Z/L) else Result:=Fallback;
end;

function WorkoutGatePlacement(Route:TGamePath;const RiderPosition,RiderForward:TVector3;
  const DistanceAhead:Single):TWorkoutGatePose;
var Cursor:TPathPosition;Here,Delta,D,Right:TVector3;Near,Error,Side:Single;
begin
  Result:=Default(TWorkoutGatePose);
  if (Route=nil) or (Route.PointCount<2) then Exit;
  { Work on a local cursor. Do not write Path.Position or use the steering carrot. }
  Cursor:=Route.ProjectFollow(RiderPosition,Route.Position,12);
  Here:=Route.RoadCenterAt(Cursor);
  Route.AdvanceFollow(Cursor,Max(0.0,DistanceAhead));
  Result.Position:=Route.RoadCenterAt(Cursor);
  D:=Route.FollowDirectionXZ(Cursor);
  Near:=EnsureRange(1-DistanceAhead/8,0.0,1.0);
  Near:=Near*Near*(3-2*Near);
  Result.Forward:=FlatDirection(D*(1-Near)+FlatDirection(RiderForward,D)*Near,D);
  { At zero distance the plane passes through the actual rendered rider,
    including lateral lane changes and longitudinal route corrections. }
  Delta:=RiderPosition-Here;
  Error:=TVector3.DotProduct(Delta,Result.Forward)*Near;
  Result.Position:=Result.Position+Result.Forward*Error;
  Result.Position.Y:=Result.Position.Y+Delta.Y*Near;
  Result.Width:=EnsureRange(Route.RoadWidthAt(Cursor)+1.0,5.0,22.0);
  Right:=Vector3(Result.Forward.Z,0,-Result.Forward.X);
  Side:=TVector3.DotProduct(Delta,Right);
  Error:=Side-EnsureRange(Side,-Result.Width*0.5+1,Result.Width*0.5-1);
  Result.Position:=Result.Position+Right*(Error*Near);
  Result.DistanceAhead:=DistanceAhead;
  Result.Visible:=True;
end;

procedure TWorkoutGateGuide.Reset;
begin
  FUpcoming:=Default(TWorkoutGatePose);FPassed:=FUpcoming;
  FHaveSample:=False;FWasRunning:=False;FRoute:=nil;
  FVisibleAge:=0;FPassedAge:=0;FCrossings:=0;
  FCrossingElapsed:=0;FCrossingPlaneError:=0;
end;

procedure TWorkoutGateGuide.Update(Player:TWorkoutPlayer;Route:TGamePath;
  const RiderPosition,RiderForward:TVector3;Speed,Seconds:Single;WorldReady:Boolean);
var Remaining,Alpha,RawAccel,PredictSpeed,Distance,Fraction,Age:Single;
    Running,Changed:Boolean;
begin
  if (Player=nil) or (Player.Plan=nil) or (Route=nil) or
     (Route.PointCount<2) or not WorldReady then begin Reset;Exit;end;
  if IsNan(Seconds) or IsInfinite(Seconds) then Seconds:=0;
  Seconds:=Max(0.0,Seconds);
  if IsNan(Speed) or IsInfinite(Speed) then Speed:=0;
  Speed:=EnsureRange(Speed,0.0,60.0);
  Changed:=not FHaveSample or (FRevision<>Player.Revision) or (FRoute<>Route) or
    (Player.Elapsed<FLastElapsed-0.00001);
  if Changed then begin
    FUpcoming.Visible:=False;FPassed.Visible:=False;FHaveSample:=False;
    FSpeed:=Speed;FAcceleration:=0;FVisibleAge:=0;FPassedAge:=0;
  end;
  if FPassed.Visible then begin
    FPassedAge:=FPassedAge+Seconds;
    FPassed.Opacity:=Sqr(Max(0.0,1-FPassedAge/1.6));
    { The film fades before the chase camera reaches it. No full-screen flash. }
    FPassed.FilmOpacity:=Max(0.0,1-FPassedAge/0.18);
    FPassed.Visible:=FPassedAge<1.6;
  end;
  if FHaveSample and FWasRunning and FUpcoming.Visible and
     (Player.Index<>FLastIndex) and (Player.Index<Player.Plan.Segments.Count) then begin
    Fraction:=1;
    if Seconds>0 then
      Fraction:=EnsureRange((Player.StageStartElapsed-FLastElapsed)/Seconds,0.0,1.0);
    FCrossingPoint:=FLastPosition+(RiderPosition-FLastPosition)*Fraction;
    FPassed:=WorkoutGatePlacement(Route,FCrossingPoint,RiderForward,0);
    FPassed.NextIndex:=Player.Index;
    FPassed.Color:=WorkoutSegmentColor(Player.Plan.Segments[Player.Index],Player.VisualPowerScale);
    FPassedAge:=Seconds*(1-Fraction);
    FPassed.Opacity:=Sqr(Max(0.0,1-FPassedAge/1.6));
    FPassed.FilmOpacity:=Max(0.0,1-FPassedAge/0.18);
    FPassed.Visible:=FPassedAge<1.6;
    FCrossingPlaneError:=Abs(TVector3.DotProduct(FCrossingPoint-FPassed.Position,FPassed.Forward));
    FCrossingElapsed:=Player.StageStartElapsed;Inc(FCrossings);
    FVisibleAge:=0;
  end;
  Running:=Player.State=wsRunning;
  if not FWasRunning then begin FSpeed:=Speed;FAcceleration:=0;end
  else if Seconds>0.00001 then begin
    Alpha:=1-Exp(-Seconds/0.6);
    RawAccel:=EnsureRange((Speed-FLastSpeed)/Seconds,-4.0,4.0);
    FAcceleration:=FAcceleration+(RawAccel-FAcceleration)*Alpha;
    FSpeed:=FSpeed+(Speed-FSpeed)*Alpha;
  end;
  Remaining:=Player.StageRemaining;
  FUpcoming.Visible:=False;
  if Running and (Player.Index+1<Player.Plan.Segments.Count) and
     (Remaining>0) and (Remaining<=WorkoutGateLeadSeconds) then begin
    FVisibleAge:=FVisibleAge+Seconds;
    { Smooth a short acceleration forecast, not the final world position.
      Multiplication by the countdown makes the placement converge to the
      rider exactly at zero, without a minimum look-ahead or a smoothing lag. }
    PredictSpeed:=FSpeed+FAcceleration*Min(1.5,Remaining*0.5);
    Alpha:=EnsureRange(Remaining/2,0.0,1.0);
    PredictSpeed:=Speed*(1-Alpha)+PredictSpeed*Alpha;
    Distance:=Max(0.5,PredictSpeed)*Remaining;
    FUpcoming:=WorkoutGatePlacement(Route,RiderPosition,RiderForward,Distance);
    FUpcoming.NextIndex:=Player.Index+1;FUpcoming.Remaining:=Remaining;
    FUpcoming.Color:=WorkoutSegmentColor(Player.Plan.Segments[Player.Index+1],Player.VisualPowerScale);
    Age:=Min(FVisibleAge,WorkoutGateLeadSeconds-Remaining);
    FUpcoming.Opacity:=EnsureRange(Age/0.35,0.0,1.0);
    FUpcoming.FilmOpacity:=1;
  end else FVisibleAge:=0;
  FRevision:=Player.Revision;FRoute:=Route;FHaveSample:=True;FWasRunning:=Running;
  FLastElapsed:=Player.Elapsed;FLastIndex:=Player.Index;
  FLastPosition:=RiderPosition;FLastSpeed:=Speed;
end;
end.
