program BotBikeFitTests;
{$mode objfpc}{$H+}
uses Classes, SysUtils, Math, fpjson, jsonparser, CastleVectors, CastleFilesUtils,
  BikeParametric, BikeParametric_Frame, BikeParametric_Fork, BikeParametric_Wheel,
  BikeParametric_Seat, BikeParametric_Crankset, BikeParametric_DropBar,
  RiderBodyParameters, GameLocalBotProfile, GameBikeAutoFit;

procedure Check(Ok:Boolean;const Msg:string);
begin if not Ok then raise Exception.Create(Msg) end;

var Owner:TComponent;Bike:TBikeInstance;Builder:TBikeBuilder;Text:TStringList;
    Root:TJSONObject;Comps:TBikeComponentClassArray;I,J:Integer;
    Frame:TFrameComponent;Seat:TSeatComponent;Crank:TCranksetComponent;
    Body:TRiderBodyParameters;BB,Top,Saddle,Rear,Front:TVector3;
    Height,MinHeight,MaxHeight:Single;
begin
  ApplicationDataOverride:=IncludeTrailingPathDelimiter(GetCurrentDir)+'data/';
  Owner:=TComponent.Create(nil);Bike:=TBikeInstance.Create(Owner);Text:=TStringList.Create;
  Root:=nil;Builder:=nil;
  try
    Text.LoadFromFile('data/bike_road2.json');Root:=TJSONObject(GetJSON(Text.Text));
    SetLength(Comps,6);
    Comps[0]:=TFrameComponent;Comps[1]:=TForkComponent;Comps[2]:=TWheelComponent;
    Comps[3]:=TSeatComponent;Comps[4]:=TCranksetComponent;Comps[5]:=TDropBarComponent;
    Bike.EnsureComponents(Comps);Bike.AssignComponentStateFromJSON(Root.Objects['components']);
    Frame:=TFrameComponent(Bike.Component(TFrameComponent));
    Seat:=TSeatComponent(Bike.Component(TSeatComponent));
    Crank:=TCranksetComponent(Bike.Component(TCranksetComponent));
    MinHeight:=10000;MaxHeight:=0;
    for I:=0 to LocalBotCatalogCount-1 do begin
      FreeAndNil(Builder);
      Builder:=TBikeBuilder.CreateBorrowing([Frame,Bike.Component(TForkComponent),
        Bike.Component(TWheelComponent),Seat,Crank,Bike.Component(TDropBarComponent)]);
      Body:=LocalBotCatalogProfile(I).Body;
      AutoFitRoadBike(Bike,Body);
      for J:=0 to Builder.ComponentCount-1 do Builder.Components[J].ComputeBones(Builder.Skeleton);
      BB:=Builder.Skeleton['bb'];Top:=Builder.Skeleton['head_tube_top'];
      Saddle:=Builder.Skeleton['saddle_contact'];
      Rear:=Builder.Skeleton['rear_axle'];Front:=Builder.Skeleton['front_axle'];
      Height:=(Saddle-BB).Length*1000;
      Check(Abs((Top.Y-BB.Y)*1000-Frame.Stack)<0.1,'stack does not match real geometry');
      Check(Abs((Top.X-BB.X)*1000-Frame.Reach)<0.1,'reach does not match real geometry');
      Check(Abs(Front.Y-Rear.Y)<0.0001,'axles must have the same height');
      Check((Frame.HeadTubeLength>=65)and(Frame.HeadTubeLength<270),'head tube out of range');
      Check((Front.X-Rear.X>0.9)and(Front.X-Rear.X<1.2),'wheelbase out of range');
      MinHeight:=Min(MinHeight,Height);MaxHeight:=Max(MaxHeight,Height);
    end;
    WriteLn(Format('BOT_BIKE_DIMENSIONS_OK: %d bodies, initial saddle %.1f..%.1f mm',[LocalBotCatalogCount,MinHeight,MaxHeight]));
  finally
    Builder.Free;Root.Free;Text.Free;Bike.Free;Owner.Free;
  end;
end.
