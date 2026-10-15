program BotBikeFitRigTests;
{$mode objfpc}{$H+}
uses Classes, SysUtils, Math, fpjson, jsonparser, CastleVectors, CastleFilesUtils,
  BikeParametric, RiderPoseCatalog, RiderBodyParameters, GameLocalBotProfile,
  GameBikeAutoFit;

function KneeFlex(B:TBikeInstance;const Side:string):Single;
var H,K,F,U,V:TVector3;
begin
  if not(B.RiderJointPos(Side+'Thigh',H)and B.RiderJointPos(Side+'Calf',K)and
    B.RiderJointPos(Side+'Foot',F))then raise Exception.Create('Missing knee joints');
  U:=H-K;V:=F-K;
  Result:=RadToDeg(ArcCos(EnsureRange(-TVector3.DotProduct(U,V)/(U.Length*V.Length),-1.0,1.0)));
end;

var Owner:TComponent;B:TBikeInstance;Text:TStringList;Root,Rider,Sample:TJSONObject;
    Comps:TBikeComponentClassArray;I,J,K,N:Integer;State:TBikePlaybackState;
    Profile:TLocalBotProfile;MinFlex,MaxFlex,ContactError,AllMin,AllMax:Single;
begin
  ApplicationDataOverride:=IncludeTrailingPathDelimiter(GetCurrentDir)+'data/';
  Text:=TStringList.Create;
  try
    Text.LoadFromFile('data/bike_road2.json');Root:=TJSONObject(GetJSON(Text.Text));
  finally Text.Free end;
  N:=LocalBotCatalogCount;if ParamCount>0 then N:=StrToInt(ParamStr(1));
  Rider:=Root.Objects['tripoRider'];Rider.Strings['path']:='castle-data:/avatars/RIDER.glb';
  Rider.Floats['scale']:=1;Rider.Floats['stanceHalf']:=0;Rider.Floats['footYawDeg']:=0;
  Comps:=TBikeInstance.PrepareBuildComps('road');AllMin:=180;AllMax:=0;
  try
    for I:=0 to N-1 do begin
      Profile:=LocalBotCatalogProfile(I);Owner:=TComponent.Create(nil);B:=TBikeInstance.Create(Owner);
      try
        B.EnsureComponents(Comps);B.AssignComponentStateFromJSON(Root.Objects['components']);
        AutoFitRoadBike(B,Profile.Body);B.Build(Comps,DefaultBikeColors,nil);
        Rider.Delete('body');Rider.Add('body',WriteRiderBody(Profile.Body));
        if not B.LoadTripoRiderFromSection(Rider) then raise Exception.Create(B.TripoRiderError);
        { Loading bots are detached from the visible scene. This must not
          turn the fitter into a query of their old/rest skeleton. }
        B.VisualDetailRequired:=False;
        if not B.FitSaddleToRider then raise Exception.Create('Fit failed: '+Profile.DisplayName);
        if B.VisualDetailRequired then raise Exception.Create('Fit changed visibility policy');
        B.VisualDetailRequired:=True;
        B.ApplyRiderPose(BuiltinRiderPose(0),0);State:=B.CaptureReplay;
        State.BodyDynamicsEnabled:=False;State.MotionCadence:=85;State.PedalRate:=85/60;
        State.CrankIntervalCur:=60/85;State.PhaseSynced:=True;State.PhaseStarted:=True;
        State.RiderEffort:=0.7;State.RiderEffortTarget:=0.7;
        MinFlex:=180;MaxFlex:=0;ContactError:=0;
        for J:=0 to 63 do begin
          State.Phase:=J/64;B.RestoreReplay(State);
          MinFlex:=Min(MinFlex,Min(KneeFlex(B,'R_'),KneeFlex(B,'L_')));
          MaxFlex:=Max(MaxFlex,Max(KneeFlex(B,'R_'),KneeFlex(B,'L_')));
          Sample:=B.RiderMotionDebugJson;
          try
            for K:=0 to 1 do ContactError:=Max(ContactError,Sample.Arrays['contact_error_m'].Floats[K]);
          finally Sample.Free end;
        end;
        WriteLn(Format('FIT %d %s: knee %.2f..%.2f, cleat %.6f m',
          [I,Profile.DisplayName,MinFlex,MaxFlex,ContactError]));
        if (MinFlex<32) or (MinFlex>38) or (MaxFlex>132) or (ContactError>0.002) then
          raise Exception.Create('Fit outside the accepted range: '+Profile.DisplayName);
        AllMin:=Min(AllMin,MinFlex);AllMax:=Max(AllMax,MinFlex);
      finally B.Free;Owner.Free end;
    end;
    WriteLn(Format('BOT_BIKE_RIG_FIT_OK: %d bodies, extension flexion %.2f..%.2f',[N,AllMin,AllMax]));
  finally Root.Free end;
end.
