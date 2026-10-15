program AutomaticBikeFitTests;
{$mode objfpc}{$H+}
uses Classes,SysUtils,Math,fpjson,jsonparser,CastleVectors,CastleFilesUtils,CastleViewport,
  BikeParametric,BikeGeometryLib,RiderBodyParameters,RiderPoseCatalog,GameBikeAutoFit;

procedure Check(B:Boolean;const Msg:string);
begin if not B then raise Exception.Create(Msg) end;

function Flexion(B:TBikeInstance;const A,C,D:string):Single;
var P,Q,R,U,V:TVector3;
begin
  Check(B.RiderJointPos(A,P)and B.RiderJointPos(C,Q)and B.RiderJointPos(D,R),'Missing fit joint');
  U:=P-Q;V:=R-Q;
  Result:=RadToDeg(ArcCos(EnsureRange(-TVector3.DotProduct(U,V)/(U.Length*V.Length),-1.0,1.0)));
end;

var Root,Rider,Sample:TJSONObject;Text,Sizes:TStringList;Geos:TBikeGeometryList;
  Info:TBikeModelInfo;B:TBikeInstance;Owner:TComponent;P:TRiderBodyParameters;
  Viewport:TCastleViewport;
  Fit,Again:TAutomaticBikeFit;State:TBikePlaybackState;
  CaseIndex,Phase,Side,K:Integer;Prefix,Model:string;T0:QWord;
  MinKnee,MaxKnee,MinElbow,MaxElbow,ContactError:Single;
begin
  ApplicationDataOverride:=IncludeTrailingPathDelimiter(GetCurrentDir)+'data/';
  Text:=TStringList.Create;Sizes:=TStringList.Create;Root:=nil;
  try
    Text.LoadFromFile('data/bike_road.json');Root:=TJSONObject(GetJSON(Text.Text));
    Rider:=Root.Objects['tripoRider'];Rider.Strings['path']:='castle-data:/avatars/RIDER.glb';
    Rider.Floats['scale']:=1;Rider.Floats['stanceHalf']:=0;Rider.Floats['footYawDeg']:=0;
    Check(ChooseRiderBikeSize(nil,Sizes,DefaultRiderBody,False)=-1,'Empty catalogue');
    for CaseIndex:=0 to 7 do begin
      P:=DefaultRiderBody;
      case CaseIndex of
        1:P:=DefaultRiderBody(1);
        2:begin P.HeightCm:=150;P.WeightKg:=44 end;
        3:begin P.HeightCm:=202;P.WeightKg:=87 end;
        4:P.ArmLengthCm:=66;
        5:P.ArmLengthCm:=49;
        6:P.InseamCm:=96;
      end;
      Model:='3t-cycling-exploro-racemax.json';
      if CaseIndex=7 then Model:='santa-cruz-bicycles-hightower.json';
      Check(ExtractBikeInsights('data/bike_jsons/'+Model,Info,Geos),'Read catalogue');
      Owner:=TComponent.Create(nil);B:=TBikeInstance.Create(Owner);
      try
        Viewport:=TCastleViewport.Create(Owner);Viewport.Items.Add(B.Group);
        CollectInsightSizes(Geos,Sizes);
        B.EnsureComponents(RoadBikeComponents);B.AssignComponentStateFromJSON(Root.Objects['components']);
        B.Build(RoadBikeComponents,DefaultBikeColors,nil);
        Rider.Delete('body');Rider.Add('body',WriteRiderBody(P));
        Check(B.LoadTripoRiderFromSection(Rider),'Load shared rider');
        T0:=GetTickCount64;
        Check(FitCatalogBike(B,Geos,Sizes,Info,P,Fit),'Fit catalogue bicycle');
        Check(Fit.SizeIndex>=0,'Selected an available size');
        Check(SameRiderBody(B.BodyParameters,NormalizeRiderBody(P)),'Fit must not resize the rider');
        Check((Fit.SeatExt>=10)and(Fit.SeatExt<=400),'Seatpost bounds');
        Check(Abs(Fit.SaddleOffset)<=50,'Rail bounds');
        Check((Fit.Spacers>=0)and(Fit.Spacers<=50),'Spacer bounds');
        Check((Fit.Stem>=60)and(Fit.Stem<=140),'Stem bounds');
        B.ApplyRiderPose(BuiltinRiderPose(0),0);State:=B.CaptureReplay;
        State.BodyDynamicsEnabled:=False;State.MotionCadence:=85;State.PedalRate:=85/60;
        State.CrankIntervalCur:=60/85;State.PhaseSynced:=True;State.PhaseStarted:=True;
        State.RiderEffort:=0.7;State.RiderEffortTarget:=0.7;
        MinKnee:=180;MaxKnee:=0;MinElbow:=180;MaxElbow:=0;ContactError:=0;
        for Phase:=0 to 31 do begin
          State.Phase:=Phase/32;B.RestoreReplay(State);
          for Side:=0 to 1 do begin
            if Side=0 then Prefix:='R_'else Prefix:='L_';
            MinKnee:=Min(MinKnee,Flexion(B,Prefix+'Thigh',Prefix+'Calf',Prefix+'Foot'));
            MaxKnee:=Max(MaxKnee,Flexion(B,Prefix+'Thigh',Prefix+'Calf',Prefix+'Foot'));
            MinElbow:=Min(MinElbow,Flexion(B,Prefix+'Upperarm',Prefix+'Forearm',Prefix+'Hand'));
            MaxElbow:=Max(MaxElbow,Flexion(B,Prefix+'Upperarm',Prefix+'Forearm',Prefix+'Hand'));
          end;
          Sample:=B.RiderMotionDebugJson;
          try for K:=0 to 3 do ContactError:=Max(ContactError,Sample.Arrays['contact_error_m'].Floats[K]);
          finally Sample.Free end;
        end;
        WriteLn(Format('FIT %d height %.0f arm %.0f inseam %.0f size %s post %.1f rail %.1f stem %.0f spacers %.0f knee %.1f..%.1f elbow %.1f..%.1f contact %.3f mm score %.2f limited %s time %d ms',
          [CaseIndex,P.HeightCm,RiderBodyArmCm(P),RiderBodyInseamCm(P),Sizes[Fit.SizeIndex],
           Fit.SeatExt,Fit.SaddleOffset,Fit.Stem,Fit.Spacers,MinKnee,MaxKnee,MinElbow,MaxElbow,
           ContactError*1000,Fit.CockpitScore,BoolToStr(Fit.Limited,True),GetTickCount64-T0]));
        Check((MinKnee>=32)and(MinKnee<=39),'Actual knee extension');
        Check(ContactError<0.006,'Hand and pedal contacts');
        if CaseIndex=7 then begin
          Check(B.BarType=btFlat,'MTB riser handlebar catalogue');
          Check(Fit.Stem<=110,'MTB cockpit bounds');
        end;
        begin
          Check(FitCatalogBike(B,Geos,Sizes,Info,P,Again),'Repeated fit');
          WriteLn(Format('REPEAT post %.3f rail %.3f stem %.0f spacers %.0f score %.3f',
            [Again.SeatExt,Again.SaddleOffset,Again.Stem,Again.Spacers,Again.CockpitScore]));
          Check((Again.SizeIndex=Fit.SizeIndex)and(Abs(Again.SeatExt-Fit.SeatExt)<0.5)and
            (Abs(Again.SaddleOffset-Fit.SaddleOffset)<0.5)and(Again.Stem=Fit.Stem)and
            (Again.Spacers=Fit.Spacers),'Repeated fitting must not accumulate offsets');
        end;
      finally B.Free;Owner.Free;Geos.Free end;
    end;
    WriteLn('AUTOMATIC_BIKE_FIT_OK');
  finally Root.Free;Sizes.Free;Text.Free end;
end.
