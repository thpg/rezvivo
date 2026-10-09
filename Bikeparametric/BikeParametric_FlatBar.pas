unit BikeParametric_FlatBar;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, CastleUtils, CastleVectors, X3DNodes,
  BikeParametric, BikeParametric_Fork, BikeGfxUtil;

type
  TFlatBarComponent = class(TBikeComponent)
  private
    FFlatBarWidth: Single;
    FFlatBarRise:  Single;
    FFlatBarSweep: Single;
    FGripColor:    Integer;   { packed $RRGGBB; -1 = inherit Ctx.Colors.Tape }
  public
    constructor Create; override;
    class function ComponentName: string; override;
    procedure ApplyPreset(const APreset: string); override;
    function BarPoint(Skel: TBikeSkeleton; SideMm: Single): TVector3;
    procedure ComputeBones(Skel: TBikeSkeleton); override;
    procedure BuildGeometry(Ctx: TBikeBuildContext); override;
  published
    property FlatBarWidth: Single  read FFlatBarWidth write FFlatBarWidth;  { mm, overall bar width }
    property FlatBarRise:  Single  read FFlatBarRise  write FFlatBarRise;   { mm, rise from clamp to grip }
    property FlatBarSweep: Single  read FFlatBarSweep write FFlatBarSweep;  { degrees, backsweep }
    { Grip colour as packed $RRGGBB (0..255 per channel).
      -1 (default) = use the global palette tape colour (Ctx.Colors.Tape). }
    property GripColor:    Integer read FGripColor    write FGripColor;
  end;

implementation

uses BikeMeshDetail;

const
  { defaults — единый источник для Create и fallback'ов ComputeBones }
  DEF_FLAT_BAR_WIDTH = 760;   { mm, overall bar width }
  DEF_FLAT_BAR_RISE  = 15;    { mm }
  DEF_FLAT_BAR_SWEEP = 8;     { degrees }
  { bare (unwrapped) bar + end-plug plastic }
  BARE_BAR_COL: TVector3 = (X: 0.02; Y: 0.02; Z: 0.022);
  BARE_BAR_SPEC: TVector3 = (X: 0.16; Y: 0.16; Z: 0.17);

{ PackRGB now lives in the shared BikeGfxUtil unit. }

constructor TFlatBarComponent.Create;
begin
  inherited Create;
  FFlatBarWidth := DEF_FLAT_BAR_WIDTH;
  FFlatBarRise  := DEF_FLAT_BAR_RISE;
  FFlatBarSweep := DEF_FLAT_BAR_SWEEP;
  FGripColor    := -1;   { inherit the global tape/grip colour by default }
end;

class function TFlatBarComponent.ComponentName: string; begin Result := 'FlatBar'; end;

procedure TFlatBarComponent.ApplyPreset(const APreset: string);
begin
  if SameText(APreset, 'mtb') then begin
    FFlatBarWidth := 780;
    FFlatBarRise  := 20;
  end;
end;

function TFlatBarComponent.BarPoint(Skel: TBikeSkeleton; SideMm: Single): TVector3;
var U,Blend,SweepMm:Single;
begin
  { The centre remains in the stem clamp. Rise and backsweep start outside it;
    the outer 125 mm is straight so the grip, palm and lever agree. }
  U:=EnsureRange((Abs(SideMm)-55)/Max(10,Min(125,FlatBarWidth*0.5-180)),0,1);Blend:=U*U*(3-2*U);
  SweepMm:=Max(0,Abs(SideMm)-55)*Tan(DegToRad(FlatBarSweep));
  Result:=Skel['stem_end']+Vector3(-SweepMm*Blend,FlatBarRise*Blend,SideMm)*Skel.MM;
end;

procedure TFlatBarComponent.ComputeBones(Skel: TBikeSkeleton);
var HalfW,Sign,A:Single;I:Integer;Side:string;Inner,Outer,Mount,ForwardAxis,Outward:TVector3;
begin
  FlatBarWidth:=EnsureRange(FlatBarWidth,400,1000);
  FlatBarRise:=EnsureRange(FlatBarRise,0,80);
  FlatBarSweep:=EnsureRange(FlatBarSweep,0,25);
  HalfW:=FlatBarWidth/2;A:=DegToRad(FlatBarSweep);
  Skel.AddBone('bar_center',Skel['stem_end']);
  for I:=0 to 1 do begin
    Sign:=1-2*I;if I=0 then Side:='r'else Side:='l';
    Inner:=BarPoint(Skel,Sign*(HalfW-125));Outer:=BarPoint(Skel,Sign*HalfW);
    Mount:=BarPoint(Skel,Sign*(HalfW-140));
    ForwardAxis:=Vector3(Cos(A),0,Sign*Sin(A));
    Outward:=Vector3(-Sin(A),0,Sign*Cos(A));
    if I=0 then Skel.AddBone('bar_right',Outer)else Skel.AddBone('bar_left',Outer);
    Skel.AddBone('grip_inner_'+Side,Inner);Skel.AddBone('grip_'+Side,Outer);
    Skel.AddBone('place_'+Side+'_1',(Inner+Outer)*0.5+Vector3(0,0.0155,0));
    Skel.AddBone('brake_mount_'+Side,Mount);
    Skel.AddBone('brake_lever_'+Side,Mount+ForwardAxis*0.026-Vector3(0,0.012,0));
    Skel.AddBone('brake_lever_end_'+Side,Mount+ForwardAxis*0.050+Outward*0.068-Vector3(0,0.035,0));
    Skel.AddBone('brake_hose_'+Side,Mount+ForwardAxis*0.041-Vector3(0,0.008,0));
  end;
end;

procedure TFlatBarComponent.BuildGeometry(Ctx: TBikeBuildContext);
var S:TBikeSkeleton;Side:string;I,J,DL,N:Integer;M,HalfW,Sign,A,Z,Radius:Single;
    Up,ForwardAxis,Outward,StemBase,StemEnd,Mount,Inner,Outer,Lever,Tip,P,Q,Head,EndHose:TVector3;
    Points:array of TVector3;Radii:array of TVector2;
    GripCol,Dark,Spec,Metal:TVector3;
  procedure Hose(const A,B,C,D:TVector3);
  var H:array of TVector3;K,Count:Integer;
  begin
    if DL=0 then Exit;
    Count:=6+DL*2;SetLength(H,Count+1);
    for K:=0 to Count do H[K]:=BikeBezier(A,B,C,D,K/Count);
    BikeDetailTube(Ctx,H,[Vector2(0.002,0.002)],Vector3(0,0,1),Dark,Spec,0.22,6);
  end;
begin
  S:=Ctx.Skeleton;M:=S.MM;DL:=Ctx.DetailLevel;HalfW:=FlatBarWidth/2;
  A:=DegToRad(FlatBarSweep);Up:=Vector3(S.HTDirX,S.HTDirY,0).Normalize;
  Dark:=Vector3(0.023,0.024,0.026);Spec:=Vector3(0.16,0.16,0.17);
  Metal:=Vector3(0.20,0.21,0.22);
  GripCol:=Ctx.Colors.Tape;if GripColor>=0 then GripCol:=PackRGB(GripColor);
  StemBase:=Ctx.O(S['stem_base']);StemEnd:=Ctx.O(S['stem_end']);Head:=Ctx.O(S['head_tube_bottom']);
  Ctx.BeginAccum(Ctx.SteerRoot);
  { Black steerer clamp, oval stem, then a real clamp around the bar centre. }
  Ctx.Add(Ctx.MakeCylinder(Ctx.O(S['head_tube_top']),StemBase+Up*0.010,0.015,Dark,Spec,0.5));
  Ctx.Add(Ctx.MakeCylinder(StemBase-Up*0.012,StemBase+Up*0.013,0.020,Dark,Spec,0.5));
  BikeDetailTube(Ctx,[StemBase,StemBase+(StemEnd-StemBase)*0.35,StemEnd],
    [Vector2(0.016,0.020),Vector2(0.014,0.018),Vector2(0.016,0.020)],
    Vector3(0,0,1),Dark,Spec,0.5);
  Ctx.Add(Ctx.MakeCylinder(StemEnd-Vector3(0,0,0.026),StemEnd+Vector3(0,0,0.026),
    0.020,Dark,Spec,0.5));
  if DL>=2 then for I:=0 to 3 do begin
    P:=StemEnd+Vector3(0.018,(2*(I div 2)-1)*0.013,(2*(I mod 2)-1)*0.019);
    Ctx.Add(Ctx.MakeCylinder(P,P+Vector3(0.003,0,0),0.003,Metal,Spec,0.6));
  end;
  N:=12;SetLength(Points,N+1);SetLength(Radii,N+1);
  for I:=0 to N do begin
    Z:=(2*I/N-1)*HalfW;Points[I]:=Ctx.O(BarPoint(S,Z));
    Radius:=0.0111+0.0048*(1-EnsureRange((Abs(Z)-45)/110,0,1));
    Radii[I]:=Vector2(Radius,Radius);
  end;
  BikeDetailTube(Ctx,Points,Radii,Vector3(0,1,0),Dark,Spec,0.38);
  for I:=0 to 1 do begin
    Sign:=1-2*I;if I=0 then Side:='r'else Side:='l';
    Inner:=Ctx.O(S['grip_inner_'+Side]);Outer:=Ctx.O(S['grip_'+Side]);
    Outward:=(Outer-Inner).Normalize;ForwardAxis:=Vector3(Cos(A),0,Sign*Sin(A));
    Ctx.Add(Ctx.MakeCylinder(Inner,Outer,0.0155,GripCol,Spec,0.23));
    Ctx.Add(Ctx.MakeCylinder(Inner-Outward*0.003,Inner+Outward*0.004,0.0163,Dark,Spec,0.5));
    Ctx.Add(Ctx.MakeCylinder(Outer-Outward*0.004,Outer+Outward*0.002,0.0160,Dark,Spec,0.4));
    if DL>=2 then for J:=1 to 10 do begin
      P:=Inner+(Outer-Inner)*(J/11);
      Ctx.Add(Ctx.MakeCylinder(P-Outward*0.0006,P+Outward*0.0006,0.0158,GripCol,Spec,0.19));
    end;
    if DL>=1 then begin
      Mount:=Ctx.O(S['brake_mount_'+Side]);Lever:=Ctx.O(S['brake_lever_'+Side]);
      Tip:=Ctx.O(S['brake_lever_end_'+Side]);
      Ctx.Add(Ctx.MakeCylinder(Mount-Outward*0.006,Mount+Outward*0.006,0.014,Dark,Spec,0.4));
      BikeDetailBox(Ctx,Mount+ForwardAxis*0.019-Vector3(0,0.005,0),
        ForwardAxis,Vector3(0,1,0),Outward*Sign,Vector3(0.036,0.021,0.022),Dark,Spec,0.35,0.8);
      BikeDetailTube(Ctx,[Lever,Lever+ForwardAxis*0.024+Outward*0.012,
        Tip+ForwardAxis*0.009-Outward*0.015,Tip],
        [Vector2(0.004,0.006),Vector2(0.0035,0.005),Vector2(0.003,0.004)],
        Vector3(0,1,0),Metal,Spec,0.5,6);
      Ctx.Add(Ctx.MakeCylinder(Lever-Vector3(0,0.010,0),Lever+Vector3(0,0.004,0),0.003,Metal,Spec,0.6));
      if I=0 then begin { one rear-shift control, below the right grip }
        P:=Mount-Vector3(0,0.022,0);
        Ctx.Add(Ctx.MakeCylinder(P-Vector3(0,0.004,0),P+Vector3(0,0.004,0),0.019,Dark,Spec,0.35));
        BikeDetailTube(Ctx,[P,P-ForwardAxis*0.015+Outward*0.020,
          P-ForwardAxis*0.030+Outward*0.025],
          [Vector2(0.005,0.003)],Vector3(0,1,0),Dark,Spec,0.25,6);
      end;
      P:=Ctx.O(S['brake_hose_'+Side]);
      if I=1 then begin
        { Front hose and caliper turn together with the fork. }
        Q:=Ctx.O(S['fork_crown_r'])+Vector3(0.033,0,-0.032);
        Hose(P,P+ForwardAxis*0.15-Vector3(0,0.02,0),Head+Vector3(0.15,-0.08,-0.04),Q);
        if S.TryGetBone('front_brake_hose_end',EndHose)then begin
          EndHose:=Ctx.O(EndHose);
          Hose(Q,Q+Vector3(0.015,-0.10,0),EndHose+Vector3(0.015,0.11,0),EndHose);
        end;
      end else begin
        { End on the steering axis: the frame-side hose stays connected. }
        Q:=Head+Up*0.025;
        Hose(P,P+ForwardAxis*0.16-Vector3(0,0.04,0),Head+Vector3(0.17,-0.06,0.03),Q);
      end;
    end;
  end;
  Ctx.EndAccum;
end;

end.
