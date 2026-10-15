unit Osm3dSceneLighting;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, CastleVectors, X3DNodes, X3DFields;
type
  TSceneLighting = record
    Enabled: Boolean;
    Tone: Integer;
    Exposure, Sun, Sky, Ground: Single;
    RoadDetail, WaterSpread, WaterReflection:Single;
  end;
const
  SCENE_LIGHTING_GLSL = {$I shaders/scene_lighting.glsl.inc};
function SceneLighting: TSceneLighting;
procedure SetSceneLighting(const Value: TSceneLighting);
procedure AttachSceneLighting(Effect: TEffectNode; Lighting:Boolean=True; Surface:Boolean=False);
implementation
uses Math;
type
  TBinding = class
    Owner:TEffectNode;
    Params, Light, Surface: TSFVec4f;
    procedure Gone(const Node: TX3DNode);
    procedure Update;
  end;
var Bindings: TList; Guard: TRTLCriticalSection; Current: TSceneLighting;
procedure TBinding.Gone(const Node: TX3DNode);
begin
  EnterCriticalSection(Guard);
  try Bindings.Remove(Self); finally LeaveCriticalSection(Guard); end;
  Free;
end;
procedure TBinding.Update;
begin
  if Params<>nil then Params.Send(Vector4(Ord(Current.Enabled), Current.Tone, Current.Exposure, 0));
  if Light<>nil then Light.Send(Vector4(Current.Sun, Current.Sky, Current.Ground, 0));
  if Surface<>nil then Surface.Send(Vector4(Current.RoadDetail,Current.WaterSpread,Current.WaterReflection,0));
end;
function SceneLighting: TSceneLighting;
begin
  EnterCriticalSection(Guard);
  try Result := Current; finally LeaveCriticalSection(Guard); end;
end;
procedure SetSceneLighting(const Value: TSceneLighting);
var I: Integer;
begin
  EnterCriticalSection(Guard);
  try
    Current := Value;
    Current.Tone := EnsureRange(Current.Tone, 0, 2);
    Current.Exposure := EnsureRange(Current.Exposure, 0.1, 4.0);
    Current.Sun := EnsureRange(Current.Sun, 0.0, 16.0);
    Current.Sky := EnsureRange(Current.Sky, 0.0, 4.0);
    Current.Ground := EnsureRange(Current.Ground, 0.0, 4.0);
    Current.RoadDetail:=EnsureRange(Current.RoadDetail,0.0,1.5);
    Current.WaterSpread:=EnsureRange(Current.WaterSpread,0.0,1.5);
    Current.WaterReflection:=EnsureRange(Current.WaterReflection,0.0,1.0);
    for I := 0 to Bindings.Count-1 do TBinding(Bindings[I]).Update;
  finally LeaveCriticalSection(Guard); end;
end;
procedure AttachSceneLighting(Effect: TEffectNode; Lighting:Boolean; Surface:Boolean);
var B: TBinding;
begin
  if (Effect.Field('rz_scene') <> nil) or (Effect.Field('rz_surface')<>nil) then Exit;
  EnterCriticalSection(Guard);
  try
    B := TBinding.Create;
    B.Owner:=Effect;
    if Lighting then begin
    B.Params := TSFVec4f.Create(Effect, True, 'rz_scene',
      Vector4(Ord(Current.Enabled), Current.Tone, Current.Exposure, 0));
    B.Light := TSFVec4f.Create(Effect, True, 'rz_light',
      Vector4(Current.Sun, Current.Sky, Current.Ground, 0));
    Effect.AddCustomField(B.Params); Effect.AddCustomField(B.Light);
    end;
    if Surface then begin
      B.Surface:=TSFVec4f.Create(Effect,True,'rz_surface',
        Vector4(Current.RoadDetail,Current.WaterSpread,Current.WaterReflection,0));
      Effect.AddCustomField(B.Surface);
    end;
    Effect.AddDestructionNotification(@B.Gone); Bindings.Add(B);
  finally LeaveCriticalSection(Guard); end;
end;
procedure ReleaseBindings;
var B:TBinding;
begin
  while Bindings.Count>0 do begin
    B:=TBinding(Bindings[Bindings.Count-1]);
    Bindings.Delete(Bindings.Count-1);
    B.Owner.RemoveDestructionNotification(@B.Gone);
    B.Free;
  end;
  FreeAndNil(Bindings);
end;
initialization
  InitCriticalSection(Guard); Bindings := TList.Create;
  Current.Enabled := True; Current.Tone := 1;
  Current.Exposure := 0.85; Current.Sun := 8.0;
  Current.Sky := 0.85; Current.Ground := 0.35;
  Current.RoadDetail:=1.0; Current.WaterSpread:=1.5; Current.WaterReflection:=0.5;
finalization
  ReleaseBindings; DoneCriticalSection(Guard);
end.
