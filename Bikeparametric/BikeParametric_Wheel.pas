unit BikeParametric_Wheel;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, CastleUtils, CastleVectors, X3DNodes,
  BikeParametric;

type
  TWheelComponent = class(TBikeComponent)
  private
    FWheelRadius: Single;     { mm, outer radius (axle to ground contact) }
    FTireWidth: Single;       { mm, tire cross-section half-width (= torus MinorR) }
    FFrontRimHeight: Single;  { mm, rim depth (extends inward from tire bead) }
    FRearRimHeight: Single;   { mm, rim depth (extends inward from tire bead) }
    FSpokeCount: Integer;
    FHubWidth: Single;
  public
    constructor Create; override;
    class function ComponentName: string; override;
    procedure ApplyPreset(const APreset: string); override;
    procedure ComputeBones(Skel: TBikeSkeleton); override;
    procedure BuildGeometry(Ctx: TBikeBuildContext); override;
  published
    property WheelRadius: Single read FWheelRadius write FWheelRadius;
    property TireWidth: Single read FTireWidth write FTireWidth;
    property FrontRimHeight: Single read FFrontRimHeight write FFrontRimHeight;
    property RearRimHeight: Single read FRearRimHeight write FRearRimHeight;
    property SpokeCount: Integer read FSpokeCount write FSpokeCount;
    property HubWidth: Single read FHubWidth write FHubWidth;
  end;

const
  { Road defaults — 700c with 28mm tire. Single source: Create seeds these,
    ComputeBones falls back to them on invalid input, and peer components
    (frame geometry, shadow/wheel-speed fallbacks) read them cross-unit. }
  DEF_WHEEL_RADIUS     = 339;   { mm, 700c }
  DEF_TIRE_WIDTH       = 14;    { mm }
  DEF_RIM_HEIGHT       = 30;    { mm }
  DEF_SPOKE_COUNT      = 16;
  DEF_HUB_WIDTH        = 60;    { mm }

implementation

uses BikeParametric_Frame, BikeMeshDetail;

{ Geometry notes:
    WheelRadius = outer radius of the tire (axle to ground contact), in mm.
    TireWidth   = tire cross-section half-width (torus MinorR), in mm.
    Torus MajorR = WheelRadius - TireWidth, so the outer edge of the
    torus reaches exactly WheelRadius and the bottom touches the ground.

    Rim = aero profile: flat outer wall (tire bead) + half-torus inner.
    Axial half-width = 80% of TireWidth so rim never pokes out past tire. }

constructor TWheelComponent.Create;
begin
  inherited Create;
  FWheelRadius    := DEF_WHEEL_RADIUS;
  FTireWidth      := DEF_TIRE_WIDTH;
  FFrontRimHeight := DEF_RIM_HEIGHT;
  FRearRimHeight  := DEF_RIM_HEIGHT;
  FSpokeCount     := DEF_SPOKE_COUNT;
  FHubWidth       := DEF_HUB_WIDTH;
end;

class function TWheelComponent.ComponentName: string; begin Result := 'Wheels'; end;

procedure TWheelComponent.ApplyPreset(const APreset: string);
begin
  if SameText(APreset, 'gravel') then begin
    WheelRadius := 349;
    TireWidth   := 20;
  end else if SameText(APreset, 'mtb') then begin
    WheelRadius := 368;
    TireWidth   := 29;
    SpokeCount  := 32;
    HubWidth    := 60;
  end;
  { 'road' (or anything else) → use defaults from Create. }
end;

procedure TWheelComponent.ComputeBones(Skel: TBikeSkeleton);
var Frame:TFrameComponent;FrontHalf,RearHalf:Single;Axle,Disc,Dir:TVector3;I:Integer;Prefix:string;R:Single;
begin
  if WheelRadius    < 200 then WheelRadius    := DEF_WHEEL_RADIUS;
  if TireWidth      < 5   then TireWidth      := DEF_TIRE_WIDTH;
  if FrontRimHeight < 5   then FrontRimHeight := DEF_RIM_HEIGHT;
  if RearRimHeight  < 5   then RearRimHeight  := DEF_RIM_HEIGHT;
  if SpokeCount     < 4   then SpokeCount     := DEF_SPOKE_COUNT;
  if HubWidth       < 20  then HubWidth       := DEF_HUB_WIDTH;
  if (Builder=nil)or(TBikeBuilder(Builder).BarType<>btFlat)then Exit;
  FrontHalf:=0.055;RearHalf:=0.074;
  Frame:=TFrameComponent(FindComponent(TFrameComponent));
  if Frame<>nil then begin
    FrontHalf:=Frame.FrontDropoutSpacing*Skel.MM/2;
    RearHalf:=Frame.RearDropoutSpacing*Skel.MM/2;
  end;
  for I:=0 to 1 do begin
    if I=0 then begin Prefix:='front';R:=0.090;Dir:=Vector3(-0.707107,0.707107,0) end
    else begin Prefix:='rear';R:=0.080;Dir:=Vector3(0.8,0.6,0) end;
    Axle:=Skel[Prefix+'_axle'];Disc:=Axle;
    if I=0 then Disc.Z:=-FrontHalf+0.012 else Disc.Z:=-RearHalf+0.012;
    Skel.AddBone(Prefix+'_brake_disc',Disc);
    Skel.AddBone(Prefix+'_brake_caliper',Disc+Dir*(R-0.007));
    Skel.AddBone(Prefix+'_brake_hose_end',Disc+Dir*(R+0.005)+Vector3(0,0,-0.010));
  end;
end;

procedure WheelQuad(Mesh:TIndexedFaceSetNode;A,B,C,D:Integer);
begin
  Mesh.FdCoordIndex.Items.Add(A);Mesh.FdCoordIndex.Items.Add(B);
  Mesh.FdCoordIndex.Items.Add(C);Mesh.FdCoordIndex.Items.Add(D);Mesh.FdCoordIndex.Items.Add(-1);
end;

procedure MountainTread(Ctx:TBikeBuildContext;MajorR,HalfWidth:Single);
const CX:array[0..3]of Single=(-1,1,1,-1);
      CY:array[0..3]of Single=(-1,-1,1,1);
var Mesh:TIndexedFaceSetNode;Coord:TCoordinateNode;Rows,I,J,K,L,Base,Next:Integer;
  A,Phi,Height,LocalR,Step,Offset,HalfLength,HalfPhi,Taper,V,W:Single;
begin
  if Ctx.DetailLevel=0 then Exit;
  case Ctx.DetailLevel of 1:Rows:=36;2:Rows:=56;else Rows:=64 end;
  Height:=Min(0.0045,HalfWidth*0.16);Step:=2*Pi/Rows;
  Coord:=TCoordinateNode.Create;Mesh:=TIndexedFaceSetNode.Create;Mesh.Coord:=Coord;
  Mesh.Solid:=True;Mesh.CreaseAngle:=0.35;
  for L:=0 to 3 do begin
    case L of
      0:begin Phi:=-0.24;Offset:=0 end;
      1:begin Phi:=0.24;Offset:=0.5 end;
      2:begin Phi:=-0.91;Offset:=0.25 end;
      else begin Phi:=0.91;Offset:=0.75 end;
    end;
    HalfPhi:=0.22;HalfLength:=0.009/MajorR;
    if L>=2 then begin HalfPhi:=0.19;HalfLength:=0.011/MajorR end;
    for I:=0 to Rows-1 do begin
      if(Ctx.DetailLevel=1)and(L>=2)and(I mod 2=1)then Continue;
      A:=(I+Offset)*Step;Base:=Coord.FdPoint.Items.Count;
      for K:=0 to 1 do begin
        if K=0 then begin LocalR:=HalfWidth-Height-0.0004;Taper:=1 end
        else begin LocalR:=HalfWidth;Taper:=0.78 end;
        for J:=0 to 3 do begin
          V:=A+CX[J]*HalfLength*Taper;W:=Phi+CY[J]*HalfPhi*Taper;
          Coord.FdPoint.Items.Add(Vector3((MajorR+LocalR*Cos(W))*Cos(V),
            (MajorR+LocalR*Cos(W))*Sin(V),LocalR*Sin(W)));
        end;
      end;
      { Bottom is buried in the casing. No hidden bottom faces. }
      WheelQuad(Mesh,Base+4,Base+5,Base+6,Base+7);
      for J:=0 to 3 do begin Next:=(J+1)mod 4;WheelQuad(Mesh,Base+J,Base+Next,Base+Next+4,Base+J+4) end;
    end;
  end;
  Ctx.EmitBatched(Mesh,Coord,Ctx.Colors.Tire*1.12,Ctx.Colors.TireSpec,0.10,0.35,TMatrix4.Identity);
end;

procedure MountainDisc(Ctx:TBikeBuildContext;Radius,Z:Single);
var Mesh:TIndexedFaceSetNode;Coord:TCoordinateNode;Segments,I,J,K,B,N,Layer:Integer;
  A,R,InnerR:Single;P,Q,Tangent,Radial,Silver:TVector3;
  function Vertex(Side,Band,Idx:Integer):Integer;
  begin Result:=Side*4*Segments+Band*Segments+(Idx mod Segments) end;
  function Filled(Band,Idx:Integer):Boolean;
  begin Result:=(Band<>1)or(Ctx.DetailLevel=0)or((Idx mod 6)<3) end;
  procedure Annulus(R0,R1:Single);
  var K:Integer;P0,P1,Q0,Q1:TVector3;Base:Integer;AA,AB:Single;
  begin
    for K:=0 to Segments-1 do begin
      AA:=K*2*Pi/Segments;AB:=(K+1)*2*Pi/Segments;Base:=Coord.FdPoint.Items.Count;
      P0:=Vector3(Cos(AA)*R0,Sin(AA)*R0,Z-0.0009);P1:=Vector3(Cos(AA)*R1,Sin(AA)*R1,Z-0.0009);
      Q0:=Vector3(Cos(AB)*R0,Sin(AB)*R0,Z-0.0009);Q1:=Vector3(Cos(AB)*R1,Sin(AB)*R1,Z-0.0009);
      Coord.FdPoint.Items.Add(P0);Coord.FdPoint.Items.Add(P1);Coord.FdPoint.Items.Add(Q1);Coord.FdPoint.Items.Add(Q0);
      Coord.FdPoint.Items.Add(P0+Vector3(0,0,0.0018));Coord.FdPoint.Items.Add(P1+Vector3(0,0,0.0018));
      Coord.FdPoint.Items.Add(Q1+Vector3(0,0,0.0018));Coord.FdPoint.Items.Add(Q0+Vector3(0,0,0.0018));
      WheelQuad(Mesh,Base+3,Base+2,Base+1,Base);WheelQuad(Mesh,Base+4,Base+5,Base+6,Base+7);
      WheelQuad(Mesh,Base+1,Base+2,Base+6,Base+5);WheelQuad(Mesh,Base+3,Base,Base+4,Base+7);
    end;
  end;
begin
  case Ctx.DetailLevel of 0:Segments:=24;1:Segments:=48;else Segments:=72 end;
  Coord:=TCoordinateNode.Create;Mesh:=TIndexedFaceSetNode.Create;Mesh.Coord:=Coord;
  Mesh.Solid:=True;Mesh.CreaseAngle:=0.35;
  InnerR:=Radius-0.017;
  for Layer:=0 to 1 do for J:=0 to 3 do for I:=0 to Segments-1 do begin
    A:=2*Pi*I/Segments;
    case J of 0:R:=InnerR;1:R:=InnerR+0.004;2:R:=Radius-0.004;else R:=Radius+0.0008*Sin(A*6) end;
    Coord.FdPoint.Items.Add(Vector3(Cos(A)*R,Sin(A)*R,Z+(2*Layer-1)*0.0009));
  end;
  for I:=0 to Segments-1 do for B:=0 to 2 do if Filled(B,I)then begin
    N:=(I+1)mod Segments;
    WheelQuad(Mesh,Vertex(0,B,I),Vertex(0,B,N),Vertex(0,B+1,N),Vertex(0,B+1,I));
    WheelQuad(Mesh,Vertex(1,B+1,I),Vertex(1,B+1,N),Vertex(1,B,N),Vertex(1,B,I));
    if(B=0)or not Filled(B-1,I)then
      WheelQuad(Mesh,Vertex(0,B,N),Vertex(0,B,I),Vertex(1,B,I),Vertex(1,B,N));
    if(B=2)or not Filled(B+1,I)then
      WheelQuad(Mesh,Vertex(0,B+1,I),Vertex(0,B+1,N),Vertex(1,B+1,N),Vertex(1,B+1,I));
    if not Filled(B,(I+Segments-1)mod Segments)then
      WheelQuad(Mesh,Vertex(0,B,I),Vertex(0,B+1,I),Vertex(1,B+1,I),Vertex(1,B,I));
    if not Filled(B,N)then
      WheelQuad(Mesh,Vertex(0,B+1,N),Vertex(0,B,N),Vertex(1,B,N),Vertex(1,B+1,N));
  end;
  Annulus(0.014,0.026);
  Silver:=Vector3(0.40,0.42,0.44);
  Ctx.EmitBatched(Mesh,Coord,Silver,Ctx.Colors.ChromeSpec,0.75,0.35,TMatrix4.Identity);
  for K:=0 to 5 do begin
    A:=K*Pi/3;Radial:=Vector3(Cos(A),Sin(A),0);Tangent:=Vector3(-Sin(A),Cos(A),0);
    P:=Radial*((InnerR+0.022)*0.5)+Vector3(0,0,Z);
    BikeDetailBox(Ctx,P,Radial,Tangent,Vector3(0,0,1),
      Vector3(InnerR-0.020,0.008,0.0018),Silver,Ctx.Colors.ChromeSpec,0.75);
    if Ctx.DetailLevel>=2 then begin
      Q:=Radial*0.022+Vector3(0,0,Z-0.002);
      Ctx.Add(Ctx.MakeCylinder(Q-Vector3(0,0,0.001),Q+Vector3(0,0,0.001),0.0028,
        Ctx.Colors.Dark,Ctx.Colors.ChromeSpec,0.5));
    end;
  end;
end;

procedure MountainCalipers(Ctx:TBikeBuildContext);
var I,K,N:Integer;Prefix:string;Center,Disc,Radial,Tangent,Drop,Head,BB,EndHose,Up:TVector3;
    Parent:TTransformNode;H:array of TVector3;Dark,Spec:TVector3;
begin
  Dark:=Vector3(0.026,0.028,0.032);Spec:=Vector3(0.20,0.21,0.23);
  for I:=0 to 1 do begin
    if I=0 then begin Prefix:='front';Parent:=Ctx.SteerRoot end
    else begin Prefix:='rear';Parent:=Ctx.Root end;
    Center:=Ctx.O(Ctx.Skeleton[Prefix+'_brake_caliper']);
    Disc:=Ctx.O(Ctx.Skeleton[Prefix+'_brake_disc']);
    Radial:=(Center-Disc).Normalize;Tangent:=Vector3(-Radial.Y,Radial.X,0);
    Ctx.BeginAccum(Parent);
    { Two pad housings straddle the disc; only the outer bridge joins them. }
    for K:=0 to 1 do BikeDetailBox(Ctx,Center+Vector3(0,0,(2*K-1)*0.0075),
      Radial,Tangent,Vector3(0,0,1),Vector3(0.021,0.042,0.010),Dark,Spec,0.4,0.85);
    BikeDetailBox(Ctx,Center+Radial*0.014,Radial,Tangent,Vector3(0,0,1),
      Vector3(0.010,0.040,0.025),Dark,Spec,0.4,0.9);
    if I=0 then Drop:=Ctx.O(Ctx.Skeleton['front_dropout_r'])+Vector3(-0.022,0.074,0)
    else Drop:=Ctx.O(Ctx.Skeleton['rear_axle'])+Vector3(0.075,0.024,Disc.Z);
    for K:=0 to 1 do begin
      Ctx.Add(Ctx.MakeCylinder(Center+Tangent*((2*K-1)*0.015)+Vector3(0,0,-0.013),
        Drop+Tangent*((2*K-1)*0.014),0.0055,Dark,Spec,0.4));
    end;
    if(I=1)and(Ctx.DetailLevel>=1)then begin
      Up:=Vector3(Ctx.Skeleton.HTDirX,Ctx.Skeleton.HTDirY,0).Normalize;
      Head:=Ctx.O(Ctx.Skeleton['head_tube_bottom'])+Up*0.025;
      BB:=Ctx.O(Ctx.Skeleton['bb'])+Vector3(0,-0.008,-0.043);
      EndHose:=Ctx.O(Ctx.Skeleton['rear_brake_hose_end']);
      N:=4+2*Ctx.DetailLevel;SetLength(H,N*2+1);
      for K:=0 to N do H[K]:=BikeBezier(Head,Head+Vector3(-0.020,-0.030,-0.034),
        BB+Vector3(0.080,0.080,0),BB,K/N);
      for K:=1 to N do H[N+K]:=BikeBezier(BB,BB+Vector3(-0.060,0.003,-0.008),
        EndHose+Vector3(0.065,-0.020,0),EndHose,K/N);
      BikeDetailTube(Ctx,H,[Vector2(0.002,0.002)],Vector3(0,0,1),Dark,Spec,0.2,6);
    end;
    Ctx.EndAccum;
  end;
end;

{ Build an aero rim ring with a half-torus inner profile. }
function MakeRimRing(Ctx: TBikeBuildContext; const Center: TVector3;
  OuterR, InnerR, HalfW: Single; Seg: Integer;
  const Color, Spec: TVector3; Shininess: Single): TTransformNode;
var
  InnerSeg: Integer;
  PPR: Integer;
  IFS: TIndexedFaceSetNode;
  Coord: TCoordinateNode;
  Shape: TShapeNode;
  I, J, NI, AK, BK, AK1, BK1: Integer;
  Theta, CT, ST, Phi, R, Z, RimH: Single;
begin
  case Ctx.DetailLevel of
    0: InnerSeg := 3;
    1: InnerSeg := 5;
    2: InnerSeg := 6;
  else InnerSeg := 8;
  end;
  RimH := OuterR - InnerR;
  PPR := InnerSeg + 1;
  Coord := TCoordinateNode.Create;

  for I := 0 to Seg - 1 do
  begin
    Theta := 2 * Pi * I / Seg;
    CT := Cos(Theta); ST := Sin(Theta);
    R := OuterR; Z := HalfW;
    Coord.FdPoint.Items.Add(Vector3(R * CT, R * ST, Z));
    for J := 1 to InnerSeg do
    begin
      Phi := Pi * J / InnerSeg;
      R := OuterR - RimH * Sin(Phi);
      Z := HalfW * Cos(Phi);
      Coord.FdPoint.Items.Add(Vector3(R * CT, R * ST, Z));
    end;
  end;

  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord; IFS.Solid := false; IFS.CreaseAngle := 1.2;
  for I := 0 to Seg - 1 do
  begin
    NI := (I + 1) mod Seg;
    AK  := I  * PPR;      BK  := NI * PPR;
    AK1 := I  * PPR + 1;  BK1 := NI * PPR + 1;
    IFS.FdCoordIndex.Items.Add(AK); IFS.FdCoordIndex.Items.Add(AK1);
    IFS.FdCoordIndex.Items.Add(BK1); IFS.FdCoordIndex.Items.Add(BK); IFS.FdCoordIndex.Items.Add(-1);

    { strips down the dished inner profile. NOTE: starts at J=1 (not J=2) — the
      J1->J2 strip was previously skipped, leaving an open wedge on the +Z bead side
      only, so the rim looked one-sided as the height grew. J=1 closes it symmetrically. }
    for J := 1 to InnerSeg - 1 do
    begin
      AK  := I  * PPR + J;      BK  := NI * PPR + J;
      AK1 := I  * PPR + J + 1;  BK1 := NI * PPR + J + 1;
      IFS.FdCoordIndex.Items.Add(AK); IFS.FdCoordIndex.Items.Add(AK1);
      IFS.FdCoordIndex.Items.Add(BK1); IFS.FdCoordIndex.Items.Add(BK); IFS.FdCoordIndex.Items.Add(-1);
    end;

    AK  := I  * PPR + InnerSeg;  BK  := NI * PPR + InnerSeg;
    AK1 := I  * PPR + 0;         BK1 := NI * PPR + 0;
    IFS.FdCoordIndex.Items.Add(AK); IFS.FdCoordIndex.Items.Add(AK1);
    IFS.FdCoordIndex.Items.Add(BK1); IFS.FdCoordIndex.Items.Add(BK); IFS.FdCoordIndex.Items.Add(-1);
  end;

  if Ctx.AccumActive then
  begin
    { батч: обод уходит в аккумулятор (crease 1.2), Shape-нода не создаётся;
      EmitBatched забирает IFS+Coord на переработку }
    Ctx.EmitBatched(IFS, Coord, Color, Spec, Shininess, 1.2,
      TranslationMatrix(Center));
    Exit(nil);
  end;

  Shape := TShapeNode.Create;
  Shape.Geometry := IFS;
  Shape.Appearance := Ctx.MakeMaterial(Color, Spec, Shininess);

  Result := TTransformNode.Create;
  Result.Translation := Center;
  Result.AddChildren(Shape);
end;

procedure TWheelComponent.BuildGeometry(Ctx: TBikeBuildContext);
var
  S: TBikeSkeleton; M, WR, TW, RimR: Single;
  RimH, RimInnerR, RimHalfW, SpokeEndR: Single;
  AxleName, DefName: string; Pos, HP1, HP2, SP1, SP2: TVector3;
  WheelTrans, RotTrans: TTransformNode;
  A, I, J, LocalSpokeCount, TireSegments: Integer; OX, OY, ZO: Single;
  Mountain:Boolean;CasingR,RimOuterR,HubAngle,RotorRadius,RotorZ,AxleHalf,FlangeZ:Single;
begin
  S := Ctx.Skeleton; M := S.MM;
  WR := WheelRadius * M;
  TW := TireWidth * M;
  RimR := WR - TW;
  Mountain:=(Builder<>nil)and(TBikeBuilder(Builder).BarType=btFlat);

  for I := 0 to 1 do
  begin
    if I = 0 then begin
      AxleName := 'rear_axle'; DefName := 'RearWheelRot';
      RimH := RearRimHeight * M;
    end else begin
      AxleName := 'front_axle'; DefName := 'FrontWheelRot';
      RimH := FrontRimHeight * M;
    end;

    RimOuterR:=RimR;
    if Mountain then RimOuterR:=WR-TW*1.6;
    RimH := Min(RimH, RimOuterR - 0.040);
    RimInnerR := RimOuterR - RimH;
    RimHalfW := TW * 0.80;
    if Mountain then RimHalfW:=Min(RimHalfW,0.0175);
    SpokeEndR := RimInnerR + 0.003;

    Pos := Ctx.O(S[AxleName]);
    WheelTrans := TTransformNode.Create;
    WheelTrans.Translation := Pos;
    RotTrans := TTransformNode.Create;
    RotTrans.X3DName := DefName;

    { батч: вся геометрия колеса (обод/покрышка/втулка/спицы) — в несколько
      мешей по материалам вместо десятков Shape-нод; RotTrans (цель роута
      WheelTimer) остаётся нетронутым }
    Ctx.BeginAccum(RotTrans);

    CasingR:=TW;TireSegments:=Ctx.LOD_TorusSeg;
    if Mountain then begin
      case Ctx.DetailLevel of 0:TireSegments:=24;1:TireSegments:=40;
        2:TireSegments:=64;else TireSegments:=96 end;
      if Ctx.DetailLevel>0 then CasingR:=TW-Min(0.0045,TW*0.16);
    end;
    Ctx.AddTo(RotTrans, Ctx.MakeTorus(TVector3.Zero, RimR, CasingR,
      Ctx.Colors.Tire, Ctx.Colors.TireSpec, 0.15,TireSegments));
    if Mountain then begin
      MountainTread(Ctx,RimR,TW);
      if I=0 then begin RotorRadius:=0.080;RotorZ:=S['rear_brake_disc'].Z end
      else begin RotorRadius:=0.090;RotorZ:=S['front_brake_disc'].Z end;
      MountainDisc(Ctx,RotorRadius,RotorZ);
    end;

    Ctx.AddTo(RotTrans, MakeRimRing(Ctx, TVector3.Zero,
      RimOuterR, RimInnerR, RimHalfW, TireSegments,
      Ctx.Colors.Rim, Ctx.Colors.RimSpec, 0.6));

    HP1 := Vector3(0, 0, -HubWidth / 2 * M);
    HP2 := Vector3(0, 0,  HubWidth / 2 * M);
    Ctx.AddTo(RotTrans, Ctx.MakeCylinder(HP1, HP2, 0.02,
      Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
    if Mountain then begin
      { Flanges support crossed spokes. The rotor carrier joins the left
        flange to the disc plane; the axle reaches both dropout faces. }
      AxleHalf:=Abs(RotorZ)+0.012;
      Ctx.Add(Ctx.MakeCylinder(Vector3(0,0,-AxleHalf),Vector3(0,0,AxleHalf),
        0.006,Ctx.Colors.Chrome,Ctx.Colors.ChromeSpec,1.0));
      for J:=0 to 1 do begin
        FlangeZ:=(2*J-1)*HubWidth*M*0.40;
        Ctx.Add(Ctx.MakeCylinder(Vector3(0,0,FlangeZ-0.002),Vector3(0,0,FlangeZ+0.002),
          0.028,Ctx.Colors.Chrome,Ctx.Colors.ChromeSpec,1.0));
      end;
      Ctx.Add(Ctx.MakeCylinder(Vector3(0,0,RotorZ),HP1+Vector3(0,0,0.004),
        0.018,Ctx.Colors.Chrome,Ctx.Colors.ChromeSpec,1.0));
      Ctx.Add(Ctx.MakeCylinder(Vector3(0,0,RotorZ-0.001),Vector3(0,0,RotorZ+0.003),
        0.026,Ctx.Colors.Chrome,Ctx.Colors.ChromeSpec,1.0));
    end;

    LocalSpokeCount := Max(4, SpokeCount div Ctx.LOD_SpokeDivisor);
    for A := 0 to LocalSpokeCount - 1 do
    begin
      OX := Cos(2 * Pi * A / LocalSpokeCount) * SpokeEndR;
      OY := Sin(2 * Pi * A / LocalSpokeCount) * SpokeEndR;
      if (A mod 2) = 0 then ZO := 0.015 else ZO := -0.015;
      SP1 := Vector3(0, 0, ZO * 0.3);
      SP2 := Vector3(OX, OY, ZO);
      if Mountain then begin
        HubAngle:=2*Pi*(A+(1-2*((A div 2)mod 2))*Min(4,LocalSpokeCount/4))/LocalSpokeCount;
        SP1:=Vector3(Cos(HubAngle)*0.025,Sin(HubAngle)*0.025,Sign(ZO)*HubWidth*M*0.40);
        SP2.Z:=Sign(ZO)*0.005;
      end;
      Ctx.AddTo(RotTrans, Ctx.MakeQuad(SP1, SP2, 0.0008,
        Ctx.Colors.Spoke, Ctx.Colors.ChromeSpec, 0.9));
    end;

    Ctx.EndAccum;

    WheelTrans.AddChildren(RotTrans);
    { Front wheel turns with steerer; rear stays on frame Root.
      AddSteered = Add when BikeDebugDisableSteer. }
    if I = 0 then
      Ctx.Add(WheelTrans)
    else
      Ctx.AddSteered(WheelTrans);
  end;
  if Mountain then MountainCalipers(Ctx);
end;

end.
