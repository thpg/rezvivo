unit RiderScreenLighting;
{$ifdef ANDROID}{$define OpenGLES}{$endif}
{$mode objfpc}{$H+}
interface

uses CastleVectors, CastleTransform, X3DNodes;

{ The viewport lends its existing RTX visibility image only while drawing live
  riders. Visibility attenuates the sun before BRDF integration / tone mapping;
  it must not multiply sky irradiance or the finished display colour. }
procedure AttachRiderScreenSun(Effect:TEffectNode);
procedure SetRiderScreenSun(Texture:Cardinal;const View:TVector4;Strength:Single);
procedure CollectRiderScreenReceivers(Candidates,Dest:TCastleTransformList);

var RiderScreenLightingEnabled:Boolean=True; { nonpersistent A/B diagnostic }

const RIDER_SCREEN_SUN_GLSL =
  'uniform sampler2D riderScreenShadow;uniform vec4 riderScreenView;'#10+
  'uniform float riderScreenStrength;'#10+
  'float riderSunVisibility(float groundShade){'#10+
  ' if(riderScreenStrength>0.0){'#10+
  '  vec2 uv=(gl_FragCoord.xy-riderScreenView.xy)/riderScreenView.zw;'#10+
  '  return 1.0-clamp(texture2D(riderScreenShadow,uv).r*riderScreenStrength,0.0,1.0);'#10+
  ' }'#10+
  ' return 1.0-0.92*clamp(groundShade,0.0,1.0);'#10+
  '}'#10;

implementation

uses Classes, X3DFields, CastleSceneCore, CastleRenderOptions,
  CastleInternalRenderer, CastleRendererInternalShader, CastleRendererInternalTextureEnv,
  {$ifdef OpenGLES}CastleGLES{$else}CastleGL{$endif};

type
  TScreenSunTexture=class(TShaderTextureNode);
  TScreenSunResource=class(TSingleTextureResource)
  protected
    class function IsClassForTextureNode(ANode:TAbstractTextureNode):Boolean;override;
    procedure PrepareCore(const Options:TCastleRenderOptions);override;
    procedure UnprepareCore;override;
  public
    function Bind(const TextureUnit:Cardinal):Boolean;override;
    function Enable(const TextureUnit:Cardinal;Shader:TShader;const Env:TTextureEnv):Boolean;override;
  end;
  TSunBinding=class
    Effect:TEffectNode;
    View:TSFVec4f;
    Strength:TSFFloat;
    procedure Gone(const Node:TX3DNode);
  end;

var Bindings:TList;Lock:TRTLCriticalSection;CurrentTexture:Cardinal;

class function TScreenSunResource.IsClassForTextureNode(ANode:TAbstractTextureNode):Boolean;
begin Result:=ANode is TScreenSunTexture end;
procedure TScreenSunResource.PrepareCore(const Options:TCastleRenderOptions);
begin end;
procedure TScreenSunResource.UnprepareCore;
begin end; { borrowed: the RTX backend owns its lifetime }
function TScreenSunResource.Bind(const TextureUnit:Cardinal):Boolean;
begin
  glActiveTexture(GL_TEXTURE0+TextureUnit);glBindTexture(GL_TEXTURE_2D,CurrentTexture);
  Result:=True;
end;
function TScreenSunResource.Enable(const TextureUnit:Cardinal;Shader:TShader;const Env:TTextureEnv):Boolean;
begin Result:=Bind(TextureUnit) end;

procedure TSunBinding.Gone(const Node:TX3DNode);
begin
  EnterCriticalSection(Lock);
  try Bindings.Remove(Self);finally LeaveCriticalSection(Lock) end;
  Free;
end;

procedure AttachRiderScreenSun(Effect:TEffectNode);
var B:TSunBinding;
begin
  B:=TSunBinding.Create;B.Effect:=Effect;
  B.Strength:=TSFFloat.Create(Effect,True,'riderScreenStrength',0);
  B.View:=TSFVec4f.Create(Effect,True,'riderScreenView',Vector4(0,0,1,1));
  Effect.AddCustomField(B.Strength);Effect.AddCustomField(B.View);
  Effect.AddCustomField(TSFNode.Create(Effect,True,'riderScreenShadow',
    [TShaderTextureNode],TScreenSunTexture.Create));
  Effect.AddDestructionNotification(@B.Gone);
  EnterCriticalSection(Lock);
  try Bindings.Add(B);finally LeaveCriticalSection(Lock) end;
end;

procedure SetRiderScreenSun(Texture:Cardinal;const View:TVector4;Strength:Single);
var I:Integer;B:TSunBinding;
begin
  CurrentTexture:=Texture;if Texture=0 then Strength:=0;
  EnterCriticalSection(Lock);
  try
    for I:=0 to Bindings.Count-1 do begin
      B:=TSunBinding(Bindings[I]);
      { Background-loaded graphs are not renderable yet. Do not send scene
        notifications while their loader is still traversing them. }
      if not (B.Effect.Scene is TCastleSceneCore) then Continue;
      if not TCastleSceneCore(B.Effect.Scene).HasWorldTransform then Continue;
      if not TCastleSceneCore(B.Effect.Scene).ExistsInRoot then Continue;
      if B.Strength.Value<>Strength then B.Strength.Send(Strength);
      if (Strength>0) and not TVector4.PerfectlyEquals(B.View.Value,View) then B.View.Send(View);
    end;
  finally LeaveCriticalSection(Lock) end;
end;

procedure CollectRiderScreenReceivers(Candidates,Dest:TCastleTransformList);
var I,J:Integer;B:TSunBinding;Parent:TCastleTransform;
begin
  Dest.Clear;if Candidates=nil then Exit;
  EnterCriticalSection(Lock);
  try
    for I:=0 to Candidates.Count-1 do begin
      if not Candidates[I].ExistsInRoot or not Candidates[I].Visible then Continue;
      for J:=0 to Bindings.Count-1 do begin
        B:=TSunBinding(Bindings[J]);
        if not (B.Effect.Scene is TCastleSceneCore) then Continue;
        if not TCastleSceneCore(B.Effect.Scene).HasWorldTransform then Continue;
        Parent:=TCastleSceneCore(B.Effect.Scene);
        while (Parent<>nil) and (Parent<>Candidates[I]) do Parent:=Parent.Parent;
        if Parent<>nil then begin Dest.Add(Parent);Break end;
      end;
    end;
  finally LeaveCriticalSection(Lock) end;
end;

initialization
  InitCriticalSection(Lock);Bindings:=TList.Create;
  TTextureResource.RegisterClass(TScreenSunResource);
end.
