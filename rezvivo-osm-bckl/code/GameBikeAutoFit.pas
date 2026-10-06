unit GameBikeAutoFit;
{$mode objfpc}{$H+}

interface

uses Classes, BikeParametric, RiderBodyParameters, BikeGeometryLib;

type
  TAutomaticBikeFit = record
    SizeIndex: Integer;
    SeatExt, SaddleOffset, Spacers, Stem, CockpitScore: Single;
    Limited: Boolean;
  end;

function ChooseRiderBikeSize(Geometries: TBikeGeometryList; Sizes: TStrings;
  const Body: TRiderBodyParameters; FlatBar: Boolean): Integer;
function FitCatalogBike(Bike: TBikeInstance; Geometries: TBikeGeometryList;
  Sizes: TStrings; const Info: TBikeModelInfo; const Body: TRiderBodyParameters;
  out Fit: TAutomaticBikeFit): Boolean;

{ Configure the persistent components BEFORE building any geometry/LOD.
  This is a starting road fit for generated riders, not a change to the
  player's saved fit. All dimensions here are millimetres. }
procedure AutoFitRoadBike(Bike: TBikeInstance; const Body: TRiderBodyParameters);

implementation

uses SysUtils, Math, fpjson, BikeParametric_Frame, BikeParametric_Fork,
  BikeParametric_Seat, BikeParametric_Crankset, BikeParametric_DropBar;

procedure RoadFrameTargets(const Body:TRiderBodyParameters;
  out Stack,Reach,SeatTube,Arms:Single);
var P:TRiderBodyParameters;Inseam,Torso:Single;
begin
  P:=NormalizeRiderBody(Body);Inseam:=10*RiderBodyInseamCm(P);
  Arms:=10*RiderBodyArmCm(P);Torso:=10*P.HeightCm-Inseam;
  SeatTube:=5*Round(Inseam*0.63/5);
  Stack:=EnsureRange(505+(Inseam-740)*0.70,490,665);
  Reach:=EnsureRange(380+0.20*(Torso-950+Arms-565),340,430);
end;

function ChooseRiderBikeSize(Geometries:TBikeGeometryList;Sizes:TStrings;
  const Body:TRiderBodyParameters;FlatBar:Boolean):Integer;
var I:Integer;G:TBikeGeometryData;Stack,Reach,SeatTube,Arms,Score,Best:Single;
begin
  Result:=-1;if(Geometries=nil)or(Sizes=nil)then Exit;
  RoadFrameTargets(Body,Stack,Reach,SeatTube,Arms);
  if FlatBar then begin Stack:=Stack+25;Reach:=Reach+55;SeatTube:=SeatTube-90 end;
  Best:=Infinity;
  for I:=0 to Sizes.Count-1 do begin
    if not FindInsightGeometry(Geometries,Sizes[I],G)then Continue;
    if(G.Stack<=0)or(G.Reach<=0)or(G.SeatTubeLength<=0)then Continue;
    { Size labels are not dimensions. Compare the actual frame geometry;
      inseam and arm length matter independently of standing height. }
    Score:=Sqr((G.Stack-Stack)/35)+Sqr((G.Reach-Reach)/25)+
      0.35*Sqr((G.SeatTubeLength-SeatTube)/60);
    if Score<Best then begin Best:=Score;Result:=I end;
  end;
end;

function FitCatalogBike(Bike:TBikeInstance;Geometries:TBikeGeometryList;
  Sizes:TStrings;const Info:TBikeModelInfo;const Body:TRiderBodyParameters;
  out Fit:TAutomaticBikeFit):Boolean;
var G:TBikeGeometryData;Snapshot,O:TJSONObject;I:Integer;Saved:TBikePlaybackState;
    OldPreset:string;OldFlat:Boolean;
begin
  Result:=False;Fit:=Default(TAutomaticBikeFit);Fit.SizeIndex:=-1;
  if(Bike=nil)or not Bike.HasTripoRider then Exit;
  Fit.SizeIndex:=ChooseRiderBikeSize(Geometries,Sizes,Body,SameText(Info.BarType,'flat'));
  if(Fit.SizeIndex<0)or not FindInsightGeometry(Geometries,Sizes[Fit.SizeIndex],G)then Exit;
  Snapshot:=TJSONObject.Create;Saved:=Bike.CaptureReplay;OldPreset:=Bike.Preset;
  OldFlat:=Bike.BarType=btFlat;
  try
    for I:=0 to Bike.ComponentCount-1 do begin
      O:=TJSONObject.Create;Snapshot.Add(Bike.Component(I).ComponentName,O);
      Bike.Component(I).ParamsToJSON(O);
    end;
    try
      ApplyGeometryToBikeInstance(Bike,G,Info);
      if not Bike.FitSaddleToRider(35,True)then
        raise Exception.Create('Could not fit the saddle to the rider rig');
      if not Bike.FitCockpitToRider(Fit.CockpitScore)then
        raise Exception.Create('Could not fit the cockpit to the rider rig');
      ReadFitAdjustments(Bike,Fit.SeatExt,Fit.SaddleOffset,Fit.Spacers,Fit.Stem);
      Fit.Limited:=(Fit.SeatExt<10.5)or(Fit.SeatExt>399.5)or(Fit.CockpitScore>8);
      Result:=True;
    except
      if OldFlat then Bike.EnsureComponents(MTBComponents)
      else Bike.EnsureComponents(RoadBikeComponents);
      Bike.AssignComponentStateFromJSON(Snapshot);Bike.Preset:=OldPreset;
      if OldFlat then Bike.BuildWithLOD(MTBComponents,Bike.LastBuildColors,nil,15,40,80)
      else Bike.BuildWithLOD(RoadBikeComponents,Bike.LastBuildColors,nil,15,40,80);
      raise;
    end;
  finally
    Bike.RestoreReplay(Saved);Snapshot.Free;
  end;
end;

procedure AutoFitRoadBike(Bike: TBikeInstance; const Body: TRiderBodyParameters);
var
  P: TRiderBodyParameters;
  Frame: TFrameComponent;
  Fork: TForkComponent;
  Seat: TSeatComponent;
  Crank: TCranksetComponent;
  Bar: TDropBarComponent;
  Inseam, Arms, HA, TargetStack, TargetReach, TargetSeatTube: Single;
begin
  Frame:=TFrameComponent(Bike.Component(TFrameComponent));
  Fork:=TForkComponent(Bike.Component(TForkComponent));
  Seat:=TSeatComponent(Bike.Component(TSeatComponent));
  Crank:=TCranksetComponent(Bike.Component(TCranksetComponent));
  Bar:=TDropBarComponent(Bike.Component(TDropBarComponent));
  if (Frame=nil) or (Fork=nil) or (Seat=nil) or (Crank=nil) or (Bar=nil) then
    raise Exception.Create('Automatic road fit requires a complete road bicycle');
  P:=NormalizeRiderBody(Body);
  Inseam:=10*RiderBodyInseamCm(P);

  { Size the frame and cockpit independently of girth/weight. Long legs
    need more stack; a longer torso/arms need more reach. Keep real wheel
    and tyre dimensions instead of scaling the whole bicycle. }
  RoadFrameTargets(P,TargetStack,TargetReach,TargetSeatTube,Arms);
  Frame.SeatTubeLength:=TargetSeatTube;
  Frame.Stack:=TargetStack;Frame.Reach:=TargetReach;
  Frame.SeatTubeAngle:=74;
  Frame.HeadTubeAngle:=73;
  Frame.BBDrop:=70;
  Frame.ChainstayLength:=410;
  Frame.EffectiveTopTubeLength:=0;
  Frame.TopTubeSeatRatio:=0.94;
  Frame.TopTubeHTRatio:=0.86;
  Frame.DownTubeHTRatio:=0.16;
  HA:=DegToRad(Frame.HeadTubeAngle);
  { Frame geometry is driven by wheelbase and head tube length, NOT the
    informational Stack/Reach fields. Solve the actual anchor equations. }
  Frame.HeadTubeLength:=(Frame.Stack-Frame.BBDrop+
    Fork.ForkRake*Cos(HA))/Sin(HA)-Fork.ForkAxleToCrown;
  Frame.Wheelbase:=Frame.ChainstayLength+Frame.Reach+
    (Fork.ForkAxleToCrown+Frame.HeadTubeLength)*Cos(HA)+Fork.ForkRake*Sin(HA);
  Fork.HeadsetSpacer:=25;
  Fork.StemLength:=5*Round(EnsureRange(90+0.20*(Arms-565),65,120)/5);
  Fork.StemAngle:=7;
  Bar.BarWidth:=10*Round(EnsureRange(P.HeightCm*2.30-10*P.Sex,360,440)/10);
  Bar.BarReach:=75;
  Bar.BarDrop:=120;
  Crank.CrankLength:=2.5*Round(EnsureRange(Inseam*0.205,155,175)/2.5);
  Crank.QFactorHalf:=ROAD_QFACTOR_HALF;

  { Temporary build height only. Once the rider is mounted, its actual
    joints and cleats determine the seat height in FitSaddleToRider.
    Do not treat an inseam coefficient as the final skeletal fit. }
  Seat.SaddleOffset:=0;
  Seat.SeatpostExtension:=100;
end;

end.
