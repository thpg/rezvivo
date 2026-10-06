unit GameBotShadow;
{$mode objfpc}{$H+}
interface
uses Classes, CastleScene, CastleTransform, CastleVectors, X3DNodes, BikeParametric;
const
  { Eleven body segments, six frame tubes and sixteen segments per wheel. }
  BotShadowMaxSegments = 49;
type
  { One small depth-only mesh in the existing atlas. No extra receiver,
    shadow texture, skin shader or material/face/hair passes for distant NPCs. }
  TBotShadow = class(TCastleScene)
  private
    FCoords:TCoordinateNode;
    FGeometry:TIndexedTriangleSetNode;
    FPoints:array[0..BotShadowMaxSegments*12-1]of TVector3;
    FIndices:array[0..BotShadowMaxSegments*60-1]of Integer;
    FWheelCircle:array[0..16]of TVector3;
  protected
    procedure LocalRender(const Params:TRenderParams);override;
  public
    Active:Boolean;
    constructor Create(AOwner:TComponent);override;
    procedure UpdatePose(Bike:TBikeInstance);
  end;
implementation
uses Math, CastleRenderOptions, CastleRenderContext, RiderRuntimeAudit;

constructor TBotShadow.Create(AOwner:TComponent);
var Root:TX3DRootNode;Shape:TShapeNode;I,K,O,L:Integer;
begin
  inherited;
  Root:=TX3DRootNode.Create;Shape:=TShapeNode.Create;
  FCoords:=TCoordinateNode.Create;FGeometry:=TIndexedTriangleSetNode.Create;
  FGeometry.Coord:=FCoords;FGeometry.Solid:=False;Shape.Geometry:=FGeometry;
  Root.AddChildren(Shape);Load(Root,True);
  Collides:=False;Pickable:=False;
  { Every segment has the same topology. Keep indices and circle samples
    for the lifetime of the proxy, without per-pose allocations or trig. }
  for I:=0 to BotShadowMaxSegments-1 do begin
    O:=I*12;L:=I*60;
    for K:=0 to 5 do begin
      FIndices[L+K*6]:=O+K;FIndices[L+K*6+1]:=O+(K+1)mod 6;FIndices[L+K*6+2]:=O+6+K;
      FIndices[L+K*6+3]:=O+6+K;FIndices[L+K*6+4]:=O+(K+1)mod 6;FIndices[L+K*6+5]:=O+6+(K+1)mod 6;
    end;
    for K:=0 to 3 do begin
      FIndices[L+36+K*6]:=O;FIndices[L+37+K*6]:=O+K+2;FIndices[L+38+K*6]:=O+K+1;
      FIndices[L+39+K*6]:=O+6;FIndices[L+40+K*6]:=O+7+K;FIndices[L+41+K*6]:=O+8+K;
    end;
  end;
  for I:=0 to High(FWheelCircle) do
    FWheelCircle[I]:=Vector3(Cos(I*Pi/8),Sin(I*Pi/8),0)*0.34;
end;

procedure TBotShadow.LocalRender(const Params:TRenderParams);
begin
  if Active and(Params.RenderingCamera.Target in[rtShadowMap,rtVarianceShadowMap])then
    inherited;
end;

procedure TBotShadow.UpdatePose(Bike:TBikeInstance);
const HexCircle:array[0..5]of TVector2=(
  (X:1;Y:0),(X:0.5;Y:0.866025404),(X:-0.5;Y:0.866025404),
  (X:-1;Y:0),(X:-0.5;Y:-0.866025404),(X:0.5;Y:-0.866025404));
var I,J,PointCount,IndexCount:Integer;A,B,C,D:TVector3;
  procedure Segment(const P,Q:TVector3;R:Single);
  var K,O:Integer;Along,Side,Up,W:TVector3;
  begin
    Along:=Q-P;if Along.Length<0.001 then Exit;Along:=Along.Normalize;
    Up:=Vector3(0,1,0);if Abs(Along.Y)>0.9 then Up:=Vector3(1,0,0);
    Side:=TVector3.CrossProduct(Along,Up).Normalize;Up:=TVector3.CrossProduct(Along,Side);
    O:=PointCount;Assert(O+12<=Length(FPoints));
    Inc(PointCount,12);
    for K:=0 to 5 do begin
      W:=(Side*HexCircle[K].X+Up*HexCircle[K].Y)*R;
      FPoints[O+K]:=P+W;FPoints[O+6+K]:=Q+W;
    end;
  end;
  procedure Limb(const First,Last:string;R:Single);
  var P,Q:TVector3;
  begin
    if Bike.RiderJointPos(First,P)and Bike.RiderJointPos(Last,Q)then
      Segment(P,Q,R*Bike.BodyParameters.HeightCm/180);
  end;
  procedure Frame(const First,Last:string;R:Single);
  var P,Q:TVector3;
  begin if Bike.BikeAnchor(First,P)and Bike.BikeAnchor(Last,Q)then Segment(P,Q,R) end;
begin
  if Bike=nil then Exit;
  CountRiderWork(rwBotShadowPose);
  PointCount:=0;
  Limb('Pelvis','Spine02',0.17);Limb('Spine02','NeckTwist01',0.18);
  Limb('R_Upperarm','R_Forearm',0.052);Limb('R_Forearm','R_Hand',0.040);
  Limb('L_Upperarm','L_Forearm',0.052);Limb('L_Forearm','L_Hand',0.040);
  Limb('R_Thigh','R_Calf',0.095);Limb('R_Calf','R_Foot',0.06);
  Limb('L_Thigh','L_Calf',0.095);Limb('L_Calf','L_Foot',0.06);
  if Bike.RiderJointPos('NeckTwist01',A)and Bike.RiderJointPos('Head',B)then begin
    D:=B-A;if D.Length>0.001 then begin D:=D.Normalize;Segment(B-D*0.03,B+D*0.18,0.10) end;
  end;
  Frame('bb','seat_tube_top',0.025);Frame('bb','head_tube_bottom',0.025);
  Frame('seat_tube_top','head_tube_top',0.022);Frame('bb','rear_axle',0.018);
  Frame('seat_tube_top','rear_axle',0.014);Frame('head_tube_bottom','front_axle',0.022);
  for J:=0 to 1 do begin
    if J=0 then begin
      if not Bike.BikeAnchor('rear_axle',C)then Continue;
    end else if not Bike.BikeAnchor('front_axle',C)then Continue;
    for I:=0 to 15 do begin
      Segment(C+FWheelCircle[I],C+FWheelCircle[I+1],0.02);
    end;
  end;
  FCoords.SetPoint(Slice(FPoints,PointCount));
  IndexCount:=(PointCount div 12)*60;
  if FGeometry.FdIndex.Count<>IndexCount then
    FGeometry.SetIndex(Slice(FIndices,IndexCount));
end;
end.
