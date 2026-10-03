unit GameWorkoutGates;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,fpjson,CastleVectors,CastleScene,CastleTransform,X3DNodes,
  GameWorkoutGateGuide,GameWorkoutPlayer,GamePhysicalAgent,GamePhysicsCommon;
type
  TWorkoutGateVisual=class
  private
    FOwner:TComponent;
    FParent:TCastleTransform;
    FScene:TCastleScene;
    FFrame,FFilm,FDetail,FBanner:TUnlitMaterialNode;
    FFrameColors:TColorNode;
    FFrameShade:array of Single;
    FLabel:TTextNode;
    FCaption:String;
    FGroundTime,FGroundOffset:Single;
    FLastColor:TVector3;
    FLastOpacity,FLastFilmOpacity:Single;
    procedure Build;
  public
    constructor Create(AOwner:TComponent;AParent:TCastleTransform;const AName:String);
    destructor Destroy;override;
    procedure Hide;
    procedure Apply(const Pose:TWorkoutGatePose;const Caption:String;
      GroundQuery:TGroundQueryFunc;Seconds:Single);
    property Scene:TCastleScene read FScene;
  end;
  TWorkoutGates=class(TComponent)
  private
    FGuide:TWorkoutGateGuide;
    FUpcoming:TWorkoutGateVisual;
  public
    constructor Create(AOwner:TComponent;AParent:TCastleTransform);reintroduce;
    destructor Destroy;override;
    procedure Reset;
    procedure Step(Player:TWorkoutPlayer;Agent:TPhysicalAgent;Seconds:Single;WorldReady:Boolean);
    function Diagnostics:TJSONObject;
  end;
implementation
uses Math,CastleColors,CastleFonts,GameMenuTheme,UiTranslations,WorkoutFile;

constructor TWorkoutGateVisual.Create(AOwner:TComponent;AParent:TCastleTransform;const AName:String);
begin
  inherited Create;FOwner:=AOwner;FParent:=AParent;
  FScene:=TCastleScene.Create(FOwner);FScene.Name:=AName;
  { A visual marker must never become a wheel/ground/camera hit or a caster. }
  FScene.Exists:=False;FScene.Pickable:=False;FScene.Collides:=False;
  FScene.CastShadows:=False;FScene.ReceiveShadowVolumes:=False;
  FScene.ProcessEvents:=False;FParent.Add(FScene);
  FLastOpacity:=-1;FLastFilmOpacity:=-1;
end;
destructor TWorkoutGateVisual.Destroy;
begin FScene.Free;inherited;end;
procedure TWorkoutGateVisual.Hide;
begin FScene.Exists:=False;FGroundTime:=0;FGroundOffset:=0;end;

procedure TWorkoutGateVisual.Build;
const Sides=8;
var Root:TX3DRootNode;Path:array[0..7]of TVector3;
    P,C:array of TVector3;Index:array of LongInt;
    I,J,N,A,B,K:Integer;Angle,Shade,X:Single;D,Normal:TVector3;
    Coords:TCoordinateNode;Colors:TColorNode;Mesh:TIndexedTriangleSetNode;
    App:TAppearanceNode;Sh:TShapeNode;Style:TFontStyleNode;Tr:TTransformNode;Brand:TTextNode;
  function Material:TUnlitMaterialNode;
  begin Result:=TUnlitMaterialNode.Create;Result.EmissiveColor:=Vector3(1,1,1);Result.Transparency:=0.5;end;
  procedure AddShape(Geometry:TAbstractGeometryNode;Mat:TUnlitMaterialNode);
  begin
    App:=TAppearanceNode.Create;App.Material:=Mat;
    Sh:=TShapeNode.Create;Sh.Geometry:=Geometry;Sh.Appearance:=App;Root.AddChildren(Sh);
  end;
  function LabelAt(const Y,Size:Single):TTextNode;
  begin
    Style:=TFontStyleNode.Create;Style.Family:=ffSans;Style.Justify:=fjMiddle;Style.Size:=Size;
    Style.CustomFont:=TCastleFont(MenuFont(True));
    Result:=TTextNode.Create;Result.FontStyle:=Style;Result.FdString.Send([' ']);
    App:=TAppearanceNode.Create;App.Material:=FDetail;
    Sh:=TShapeNode.Create;Sh.Geometry:=Result;Sh.Appearance:=App;
    Tr:=TTransformNode.Create;Tr.Translation:=Vector3(0,Y,0.205);Tr.AddChildren(Sh);Root.AddChildren(Tr);
  end;
begin
  Root:=TX3DRootNode.Create;
  FFrame:=Material;FFilm:=Material;FDetail:=Material;FBanner:=Material;
  FBanner.EmissiveColor:=Vector3(0.025,0.045,0.065);
  Path[0]:=Vector3(-3,-0.45,0);Path[1]:=Vector3(-3,2.9,0);
  Path[2]:=Vector3(-2.9,3.5,0);Path[3]:=Vector3(-2.55,3.85,0);
  Path[4]:=Vector3(2.55,3.85,0);Path[5]:=Vector3(2.9,3.5,0);
  Path[6]:=Vector3(3,2.9,0);Path[7]:=Vector3(3,-0.45,0);
  SetLength(P,Length(Path)*Sides);SetLength(C,Length(P));
  SetLength(FFrameShade,Length(P));
  SetLength(Index,(Length(Path)-1)*Sides*6);K:=0;
  for I:=0 to High(Path)do begin
    D:=Path[Min(High(Path),I+1)]-Path[Max(0,I-1)];D:=D.Normalize;
    Normal:=Vector3(-D.Y,D.X,0);
    for J:=0 to Sides-1 do begin
      N:=I*Sides+J;Angle:=J*2*Pi/Sides;
      P[N]:=Path[I]+Normal*(0.15*Cos(Angle))+Vector3(0,0,0.15*Sin(Angle));
      Shade:=0.72+0.28*Sin(Angle);C[N]:=Vector3(Shade,Shade,Shade);
      FFrameShade[N]:=Shade;
      if I<High(Path)then begin
        A:=I*Sides+J;B:=(I+1)*Sides+J;
        Index[K]:=A;Index[K+1]:=I*Sides+(J+1)mod Sides;Index[K+2]:=B;
        Index[K+3]:=Index[K+1];Index[K+4]:=(I+1)*Sides+(J+1)mod Sides;Index[K+5]:=B;Inc(K,6);
      end;
    end;
  end;
  Coords:=TCoordinateNode.Create;Coords.SetPoint(P);Colors:=TColorNode.Create;Colors.SetColor(C);
  FFrameColors:=Colors;
  Mesh:=TIndexedTriangleSetNode.Create;Mesh.Coord:=Coords;Mesh.Color:=Colors;
  Mesh.ColorPerVertex:=True;Mesh.Solid:=True;Mesh.SetIndex(Index);AddShape(Mesh,FFrame);
  { One two-sided film; no texture, depth offset, collision or animated shader. }
  Coords:=TCoordinateNode.Create;Coords.SetPoint([
    Vector3(-2.80,0.025,0),Vector3(2.80,0.025,0),Vector3(2.80,2.95,0),
    Vector3(2.65,3.40,0),Vector3(2.40,3.64,0),Vector3(-2.40,3.64,0),
    Vector3(-2.65,3.40,0),Vector3(-2.80,2.95,0)]);
  Mesh:=TIndexedTriangleSetNode.Create;Mesh.Coord:=Coords;Mesh.Solid:=False;
  Mesh.SetIndex([0,1,2,0,2,3,0,3,4,0,4,5,0,5,6,0,6,7]);AddShape(Mesh,FFilm);
  { A dark translucent header gives the countdown a readable home in the arch. }
  Coords:=TCoordinateNode.Create;Coords.SetPoint([
    Vector3(-2.53,3.08,0.16),Vector3(2.53,3.08,0.16),
    Vector3(2.53,3.65,0.16),Vector3(-2.53,3.65,0.16)]);
  Mesh:=TIndexedTriangleSetNode.Create;Mesh.Coord:=Coords;Mesh.Solid:=False;
  Mesh.SetIndex([0,1,2,0,2,3]);AddShape(Mesh,FBanner);
  { Small chequered shoulders make the marker read as a race arch. One batch. }
  SetLength(P,16*4);SetLength(Index,16*6);
  for I:=0 to 15 do begin
    X:=-2.45+I*0.32;
    J:=I*4;P[J]:=Vector3(X,3.77+(I mod 2)*0.08,0.203);
    P[J+1]:=P[J]+Vector3(0.16,0,0);P[J+2]:=P[J]+Vector3(0.16,0.08,0);P[J+3]:=P[J]+Vector3(0,0.08,0);
    K:=I*6;Index[K]:=J;Index[K+1]:=J+1;Index[K+2]:=J+2;
    Index[K+3]:=J;Index[K+4]:=J+2;Index[K+5]:=J+3;
  end;
  Coords:=TCoordinateNode.Create;Coords.SetPoint(P);
  Mesh:=TIndexedTriangleSetNode.Create;Mesh.Coord:=Coords;Mesh.Solid:=False;Mesh.SetIndex(Index);
  AddShape(Mesh,FDetail);
  Brand:=LabelAt(3.54,0.12);Brand.FdString.Send(['REZVIVO']);
  FLabel:=LabelAt(3.23,0.23);
  FScene.Load(Root,True);
end;

procedure TWorkoutGateVisual.Apply(const Pose:TWorkoutGatePose;const Caption:String;
  GroundQuery:TGroundQueryFunc;Seconds:Single);
var P,C:TVector3;Y,FilmOpacity:Single;VertexColors:array of TVector3;I:Integer;
begin
  if not Pose.Visible or (Pose.Opacity<0.001)then begin Hide;Exit;end;
  if FFrame=nil then Build;
  P:=Pose.Position;FGroundTime:=FGroundTime-Max(0.0,Seconds);
  if (Pose.DistanceAhead>6) and Assigned(GroundQuery) and (FGroundTime<=0)then begin
    if GroundQuery(P.X,P.Z,P.Y,Y)then FGroundOffset:=Y-P.Y else FGroundOffset:=0;
    FGroundTime:=0.2;
  end;
  P.Y:=P.Y+FGroundOffset*EnsureRange(Pose.DistanceAhead/6,0.0,1.0);
  FScene.Translation:=P;FScene.Rotation:=Vector4(0,1,0,ArcTan2(-Pose.Forward.X,-Pose.Forward.Z));
  FScene.Scale:=Vector3(Pose.Width/6,1,1);
  C:=Vector3(Pose.Color.X,Pose.Color.Y,Pose.Color.Z);
  if not TVector3.Equals(C,FLastColor)then begin
    { In CGE vertex colors replace an unlit material's RGB. Tint the small
      static frame buffer only when the interval color actually changes. }
    SetLength(VertexColors,Length(FFrameShade));
    for I:=0 to High(VertexColors)do VertexColors[I]:=C*FFrameShade[I];
    FFrameColors.SetColor(VertexColors);
    FFilm.FdEmissiveColor.Send(C);FLastColor:=C;
  end;
  if Pose.Opacity<>FLastOpacity then begin
    FFrame.FdTransparency.Send(1-0.82*Pose.Opacity);
    FBanner.FdTransparency.Send(1-0.78*Pose.Opacity);
    FDetail.FdTransparency.Send(1-0.94*Pose.Opacity);FLastOpacity:=Pose.Opacity;
  end;
  FilmOpacity:=Pose.Opacity*Pose.FilmOpacity;
  if FilmOpacity<>FLastFilmOpacity then begin
    FFilm.FdTransparency.Send(1-0.075*FilmOpacity);FLastFilmOpacity:=FilmOpacity;
  end;
  if FCaption<>Caption then begin FCaption:=Caption;FLabel.FdString.Send([Caption]);end;
  FScene.Exists:=True;
end;

constructor TWorkoutGates.Create(AOwner:TComponent;AParent:TCastleTransform);
begin
  inherited Create(AOwner);FGuide:=TWorkoutGateGuide.Create;
  FUpcoming:=TWorkoutGateVisual.Create(Self,AParent,'WorkoutGateUpcoming');
end;
destructor TWorkoutGates.Destroy;
begin FUpcoming.Free;FGuide.Free;inherited;end;
procedure TWorkoutGates.Reset;
begin FGuide.Reset;FUpcoming.Hide;end;

procedure TWorkoutGates.Step(Player:TWorkoutPlayer;Agent:TPhysicalAgent;Seconds:Single;WorldReady:Boolean);
var P:TVector3;Caption:String;Pose:TWorkoutGatePose;Target:Integer;Next:TWorkoutSegment;
begin
  if (Agent=nil)or(Agent.State=nil)then begin Reset;Exit;end;
  P:=Agent.State.WorldPosition;
  if Agent.Actor.Transform<>nil then P:=Agent.Actor.Transform.Translation;
  P.Y:=Agent.State.LastGroundY;
  FGuide.Update(Player,Agent.Path,P,Agent.State.ForwardDir,Agent.State.CurrentSpeed,Seconds,WorldReady);
  Pose:=FGuide.Upcoming;Caption:='';
  if Pose.Visible then begin
    if Pose.Finish then Caption:=UiText('Finish')
    else Caption:=Format(UiText('Interval %d'),[Pose.NextIndex+1]);
    Caption:=Caption+' · '+Format(UiText('%ds'),[Ceil(Pose.Remaining)]);
    Next:=nil;if not Pose.Finish then Next:=Player.Plan.Segments[Pose.NextIndex];
    if (Next<>nil) and (Player.ReferenceWatts>0) and (Next.Kind<>wskFreeRide)then begin
      Target:=Round(Next.PowerLow*Player.ReferenceWatts*Player.Intensity);
      Caption:=Caption+' · '+IntToStr(Target)+UiText(' W');
    end;
  end;
  FUpcoming.Apply(Pose,Caption,Agent.State.GroundQuery,Seconds);
end;

function TWorkoutGates.Diagnostics:TJSONObject;
  function PoseJson(const P:TWorkoutGatePose):TJSONObject;
  begin
    Result:=TJSONObject.Create(['visible',P.Visible,'finish',P.Finish,
      'next_index',P.NextIndex,'remaining',P.Remaining,'ahead_m',P.DistanceAhead,
      'width',P.Width,'opacity',P.Opacity,'collides',False,'pickable',False]);
    Result.Add('position',TJSONArray.Create([P.Position.X,P.Position.Y,P.Position.Z]));
    Result.Add('forward',TJSONArray.Create([P.Forward.X,P.Forward.Y,P.Forward.Z]));
    Result.Add('color',TJSONArray.Create([P.Color.X,P.Color.Y,P.Color.Z]));
  end;
begin
  Result:=TJSONObject.Create(['lead_seconds',WorkoutGateLeadSeconds,'crossings',FGuide.Crossings,
    'crossing_elapsed',FGuide.CrossingElapsed,'crossing_plane_error_m',FGuide.CrossingPlaneError]);
  Result.Add('upcoming',PoseJson(FGuide.Upcoming));
  Result.Objects['upcoming'].Add('rendered',FUpcoming.Scene.Exists);
  Result.Add('passed',PoseJson(FGuide.Passed));
  Result.Objects['passed'].Add('rendered',False);
  Result.Add('crossing_point',TJSONArray.Create([FGuide.CrossingPoint.X,FGuide.CrossingPoint.Y,FGuide.CrossingPoint.Z]));
end;
end.
