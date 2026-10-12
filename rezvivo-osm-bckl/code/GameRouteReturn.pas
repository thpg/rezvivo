unit GameRouteReturn;
{$mode objfpc}{$H+}
interface
uses Classes,Math,CastleVectors,CastleScene,CastleTransform,X3DNodes,GamePath,Osm3dTravelRoads,
  GamePhysicalAgent;
type
  TRouteReturnGuide=class
  private
    FScene:TCastleScene;
    FTimer:Single;
    FTargetValid:Boolean;
  public
    Target:TPathPosition;
    Point:TVector3;
    Distance:Single;
    constructor Create(Owner:TComponent;Parent:TCastleTransform);
    destructor Destroy;override;
    procedure Step(Path:TGamePath;const P,Heading:TVector3;Dt:Single;Active:Boolean);
    procedure Hide;
  end;
function NearestRoutePoint(Path:TGamePath;const P:TVector3;out Point:TVector3):TPathPosition;overload;
function NearestRoutePoint(Path:TGamePath;const P,Heading:TVector3;
  const Seed:TPathPosition;out Point:TVector3):TPathPosition;overload;
function RouteTurnFollowsPath(Path:TGamePath;const Seed:TPathPosition;
  const Road:TTravelRoad;Direction:Integer):Boolean;
function RouteReturnAligned(Distance,HeadingDot,ManualAxis:Single;TurnPending:Boolean):Boolean;
function RestoredRouteExcursion(Agent:TPhysicalAgent;PointExplore:Boolean):Boolean;
procedure ResumeAgentRoute(Agent:TPhysicalAgent;const Target:TPathPosition);
implementation
function NearestRoutePoint(Path:TGamePath;const P:TVector3;out Point:TVector3):TPathPosition;
var Seed:TPathPosition;
begin
  Seed:=Default(TPathPosition);if Path<>nil then Seed:=Path.Position;
  Result:=NearestRoutePoint(Path,P,Vector3(0,0,0),Seed,Point);
end;
function NearestRoutePoint(Path:TGamePath;const P,Heading:TVector3;
  const Seed:TPathPosition;out Point:TVector3):TPathPosition;
var I,N,Gap,BestGap:Integer;R:TTravelRoad;Q,H:TVector3;Cursor:TPathPosition;
  T,D,Best,Dot,BestDot:Single;
begin
  Result:=Default(TPathPosition);Point:=P;Best:=1e30;BestDot:=-2;BestGap:=MaxInt;
  if(Path=nil)or(Path.PointCount<2)then Exit;
  N:=Path.PointCount;
  for I:=0 to N-1 do begin
    Cursor.Segment:=I;Cursor.T:=0;
    R.A:=Path.RoadCenterAt(Cursor);R.B:=R.A+Path.FollowTangent(Cursor);
    if RoadDistanceSq(R.A,R.B)<1e-8 then Continue;
    Q:=RoadProjection(P,R,T);D:=RoadDistanceSq(P,Q)+Sqr((P.Y-Q.Y)*0.25);
    H:=Path.FollowDirectionXZ(Cursor);Dot:=TVector3.DotProduct(H,Heading);
    Gap:=Abs(I-Seed.Segment);Gap:=Min(Gap,N-Gap);
    { Coincident out-and-back branches need their direction, not array order.
      Continuity resolves equally aligned crossings/laps after that. }
    if(D<Best-0.04)or((Abs(D-Best)<=0.04)and
      ((Dot>BestDot+0.01)or((Abs(Dot-BestDot)<=0.01)and(Gap<BestGap))))then begin
      Best:=D;BestDot:=Dot;BestGap:=Gap;Result.Segment:=I;Result.T:=T;Point:=Q;
    end;
  end;
end;

function RouteTurnFollowsPath(Path:TGamePath;const Seed:TPathPosition;
  const Road:TTravelRoad;Direction:Integer):Boolean;
var H,Sample,Q:TVector3;Cursor:TPathPosition;LengthXZ,Along:Single;
begin
  Result:=False;if(Path=nil)or(Path.PointCount<2)then Exit;
  H:=(Road.B-Road.A)*Direction;H.Y:=0;LengthXZ:=H.Length;
  if LengthXZ<0.01 then Exit;H:=H/LengthXZ;
  if Direction>0 then Sample:=Road.A else Sample:=Road.B;
  Along:=Min(8.0,LengthXZ*0.75);Sample:=Sample+H*Along;
  Cursor:=Path.ProjectFollow(Sample,Seed,60);Q:=Path.RoadCenterAt(Cursor);
  Result:=(RoadDistanceSq(Sample,Q)<Sqr(1.5))and
    (TVector3.DotProduct(H,Path.FollowDirectionXZ(Cursor))>0.97);
end;

function RouteReturnAligned(Distance,HeadingDot,ManualAxis:Single;TurnPending:Boolean):Boolean;
begin
  Result:=(Distance<1.5)and(HeadingDot>0.85)and(Abs(ManualAxis)<0.15)and not TurnPending;
end;

function RestoredRouteExcursion(Agent:TPhysicalAgent;PointExplore:Boolean):Boolean;
begin
  Result:=(Agent<>nil)and Agent.State.FreeTravel and not PointExplore and(Agent.Path.PointCount>2);
end;

procedure ResumeAgentRoute(Agent:TPhysicalAgent;const Target:TPathPosition);
begin
  if Agent=nil then Exit;
  Agent.Path.Position:=Target;Agent.Path.ResetTurnaround;
  Agent.Path.SmoothedRouteDir:=Agent.State.ForwardDir;
  Agent.State.FreeTravel:=False;Agent.State.TravelOffRoad:=False;
  Agent.State.TravelRoadGuided:=False;
end;
constructor TRouteReturnGuide.Create(Owner:TComponent;Parent:TCastleTransform);
const Outline:array[0..6]of Integer=(0,1,3,5,6,4,2);
var Root:TX3DRootNode;Shape:TShapeNode;App:TAppearanceNode;Mat:TUnlitMaterialNode;
  Mesh:TIndexedTriangleSetNode;Coords:TCoordinateNode;
  I,A,B:Integer;V:TVector3;
  procedure Tri(A,B,C:Integer);
  begin Mesh.FdIndex.Items.Add(A);Mesh.FdIndex.Items.Add(B);Mesh.FdIndex.Items.Add(C)end;
begin
  inherited Create;
  FScene:=TCastleScene.Create(Owner);FScene.Name:='ReturnToRouteArrow';
  FScene.Collides:=False;FScene.Pickable:=False;FScene.CastShadows:=False;
  FScene.ProcessEvents:=False;FScene.Exists:=False;
  Root:=TX3DRootNode.Create;Shape:=TShapeNode.Create;App:=TAppearanceNode.Create;
  Mat:=TUnlitMaterialNode.Create;Mat.EmissiveColor:=Vector3(0.1,0.8,1);Mat.Transparency:=0.15;
  App.Material:=Mat;Shape.Appearance:=App;
  Coords:=TCoordinateNode.Create;
  Coords.FdPoint.Items.Add(Vector3(-0.11,0,0.6));Coords.FdPoint.Items.Add(Vector3(0.11,0,0.6));
  Coords.FdPoint.Items.Add(Vector3(-0.11,0,-0.05));Coords.FdPoint.Items.Add(Vector3(0.11,0,-0.05));
  Coords.FdPoint.Items.Add(Vector3(-0.45,0,-0.05));Coords.FdPoint.Items.Add(Vector3(0.45,0,-0.05));
  Coords.FdPoint.Items.Add(Vector3(0,0,-0.8));
  Mesh:=TIndexedTriangleSetNode.Create;Mesh.Coord:=Coords;Mesh.Solid:=False;
  Mesh.FdIndex.Items.Add(0);Mesh.FdIndex.Items.Add(1);Mesh.FdIndex.Items.Add(2);
  Mesh.FdIndex.Items.Add(1);Mesh.FdIndex.Items.Add(3);Mesh.FdIndex.Items.Add(2);
  Mesh.FdIndex.Items.Add(4);Mesh.FdIndex.Items.Add(5);Mesh.FdIndex.Items.Add(6);
  { A flat ground-parallel triangle vanishes from a low chase camera.
    A shallow prism reads as an arrow from front, side and overhead. }
  for I:=0 to 6 do begin
    V:=Coords.FdPoint.Items[I];V.Y:=0.12;Coords.FdPoint.Items[I]:=V;
    V.Y:=-0.12;Coords.FdPoint.Items.Add(V);
  end;
  Tri(9,8,7);Tri(9,10,8);Tri(13,12,11);
  for I:=0 to 6 do begin A:=Outline[I];B:=Outline[(I+1)mod 7];Tri(A,B,A+7);Tri(B,B+7,A+7)end;
  Shape.Geometry:=Mesh;Root.AddChildren(Shape);FScene.Load(Root,True);Parent.Add(FScene);
end;
destructor TRouteReturnGuide.Destroy;
begin FScene.Free;inherited end;
procedure TRouteReturnGuide.Hide;
begin FScene.Exists:=False;FTimer:=0;FTargetValid:=False end;
procedure TRouteReturnGuide.Step(Path:TGamePath;const P,Heading:TVector3;Dt:Single;Active:Boolean);
var D:TVector3;Seed:TPathPosition;
begin
  if not Active or(Path=nil)or(Path.PointCount<2)then begin Hide;Exit end;
  FTimer:=FTimer-Dt;
  if(FTimer<=0)or not FTargetValid then begin
    Seed:=Target;if not FTargetValid then Seed:=Path.Position;
    FTimer:=0.5;Target:=NearestRoutePoint(Path,P,Heading,Seed,Point);FTargetValid:=True;
  end else begin
    { Refresh the nearby projection every frame. Measuring to a half-second
      old point adds forward travel to the lateral error and prevents rejoin. }
    Target:=Path.ProjectFollow(P,Target,20);Point:=Path.RoadCenterAt(Target);
  end;
  Distance:=Sqrt(RoadDistanceSq(P,Point));FScene.Exists:=Distance>2.5;
  D:=Point-P;
  FScene.Translation:=P+Heading*2.8+Vector3(0,1.0,0);
  FScene.Rotation:=Vector4(0,1,0,ArcTan2(-D.X,-D.Z));
end;
end.
