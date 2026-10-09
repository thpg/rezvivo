unit GameGraphicsBenchmarkRiders;
{$mode objfpc}{$H+}
interface
uses Classes, CastleViewport, CastleTransform, BikeParametric, RiderTripo,
  GameRiderShaderWarmup;
const GraphicsBenchmarkRiderCount = 4;
type
  { Same models, body parameters, GPU animation and staged shader warmup as
    local companions. No physics, network or profile changes in this scene. }
  TGraphicsBenchmarkRiders = class
  private
    FOwner: TComponent;
    FBikes: array[0..GraphicsBenchmarkRiderCount-1] of TBikeInstance;
    FActors: array[0..GraphicsBenchmarkRiderCount-1] of TCastleTransform;
    FWorker: TTripoGlbWorker;
    FWarmup: TRiderShaderWarmup;
    FJson: string;
    FIndex, FStage: Integer;
  public
    constructor Create(Owner: TComponent);
    destructor Destroy; override;
    function PrepareStep(Viewport: TCastleViewport): Boolean;
    procedure Animate(Dt: Single);
    procedure AddCasters(List: TCastleTransformList);
  end;
implementation
uses SysUtils, Math, fpjson, jsonparser, CastleVectors, CastleBoxes,
  GameBikeAvatar, GameLocalBotProfile, RiderBodyParameters, AppSettings;

constructor TGraphicsBenchmarkRiders.Create(Owner: TComponent);
begin
  inherited Create;
  FOwner:=Owner;
  FWarmup:=TRiderShaderWarmup.Create;
end;

destructor TGraphicsBenchmarkRiders.Destroy;
var I: Integer;
begin
  FreeAndNil(FWorker);
  FreeAndNil(FWarmup);
  for I:=0 to High(FBikes) do begin
    FreeAndNil(FBikes[I]);
    FreeAndNil(FActors[I]);
  end;
  inherited;
end;

function TGraphicsBenchmarkRiders.PrepareStep(Viewport: TCastleViewport): Boolean;
const Catalog: array[0..3] of Integer = (0, 9, 22, 37);
var B: TBikeInstance; P: TLocalBotProfile; Slot: TClothSlot;
  Text: TStringList; Config, Rider: TJSONObject; Contact:TVector3;
begin
  Result:=FIndex>=GraphicsBenchmarkRiderCount;
  if Result then Exit;
  P:=LocalBotCatalogProfile(Catalog[FIndex]);
  B:=FBikes[FIndex];
  case FStage of
    0:begin
      Text:=TStringList.Create;
      try
        Text.LoadFromFile(BikeJsonUrlToFilename('castle-data:/bike_road.json'));
        Config:=TJSONObject(GetJSON(Text.Text));
      finally Text.Free end;
      try
        Rider:=Config.Objects['tripoRider'];
        Rider.Delete('body');Rider.Add('body',WriteRiderBody(P.Body));
        FJson:=Config.AsJSON;
      finally Config.Free end;
      FWorker:=TTripoGlbWorker.Create(ResolveRiderGlbPath('castle-data:/avatars/RIDER.glb'));
      B:=LoadBikeInstanceFromJSONString(FJson,FOwner,12,30,65,False,True,True);
      FBikes[FIndex]:=B;B.ShadowMode:=bsmNone;
      FActors[FIndex]:=TCastleTransform.Create(FOwner);
      FActors[FIndex].Add(B.Group);
      B.ClothDyePresetMode:=cdmShader;
      for Slot:=Low(Slot) to High(Slot) do B.StageRiderClothColor(Slot,P.Colors[Slot]);
    end;
    1:begin
      if not FWorker.Finished then Exit;
      AttachTripoRiderFromJSON(B,FJson,FWorker.Prepared);
      FreeAndNil(FWorker);FJson:='';
      if not B.HasTripoRider then raise Exception.Create('Benchmark rider: '+B.TripoRiderError);
      if not B.FitSaddleToRider then raise Exception.Create('Benchmark rider fit failed');
    end;
    2:begin
      B.TripoRider.HairStyle:=P.Hair;
      B.TripoRider.SetHeadAppearance(P.Headwear,P.Beard,P.Mustache);
      B.SetHeadwearColorLive(P.Helmet,True);
      B.SetFrameColorLive(P.Frame);B.SetRimColorLive(P.Rim);
      B.SetAnimationSpeed(60/(78+FIndex*4),0);
      B.SetWheelSpeedMps(8);
      B.ShadowSunWorldDir:=Vector3(-0.55,0.75,-0.35).Normalize;
      B.AnimateFrame(Single(0));
      FActors[FIndex].Rotation:=Vector4(0,1,0,-Pi/2);
      FActors[FIndex].Translation:=Vector3(-1.6+(FIndex mod 2)*2.7,0,FIndex*4);
      Viewport.Items.Add(FActors[FIndex]);
      try
        if B.WheelSupportPoint(False,Vector3(0,1,0),Contact) then
          FActors[FIndex].Translation:=FActors[FIndex].Translation-Vector3(0,Contact.Y,0);
      finally Viewport.Items.Remove(FActors[FIndex]) end;
      B.RiderScene.RenderOptions.CachedAnimationRevision:=1;
    end;
    3:Viewport.PrepareResources(B.Group,[]);
    4:begin
      if not FWarmup.Step(Viewport,FActors[FIndex],B.Group,B.RiderScene) then Exit;
      Viewport.Items.Add(FActors[FIndex]);
    end;
  end;
  Inc(FStage);
  if FStage>4 then begin
    Inc(FIndex);FStage:=0;
    Result:=FIndex>=GraphicsBenchmarkRiderCount;
    if Result then FWarmup.Finish;
  end;
end;

procedure TGraphicsBenchmarkRiders.Animate(Dt: Single);
var I: Integer;
begin
  for I:=0 to FIndex-1 do begin
    FBikes[I].AnimateFrame(Dt);
    Inc(FBikes[I].RiderScene.RenderOptions.CachedAnimationRevision);
  end;
end;

procedure TGraphicsBenchmarkRiders.AddCasters(List: TCastleTransformList);
var I: Integer;
begin
  for I:=0 to FIndex-1 do List.Add(FActors[I]);
end;
end.
