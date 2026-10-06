unit Osm3dRtxMaterials;
{$mode objfpc}{$H+}
interface
uses Classes, CastleVectors, CastleShapes, X3DNodes, X3DFields;
procedure AttachRtxMaterial(Effect:TEffectNode);
procedure AttachRtxGroundCaptureFlag(Effect:TEffectNode);
procedure SetRtxMaterialPass(Capture:Boolean;Texture:Cardinal;const View:TVector4);
procedure SetRtxMaterialViewport(const View:TVector4);
function RtxMaterialViewport:TVector4;
function IsRtxReflector(const Shape:TShape):Boolean;
function IsRtxGround(const Shape:TShape):Boolean;
function RtxReflectionCaptureActive:Boolean;
function RtxReflectionsAvailable:Boolean;
const RTX_MATERIAL_GLSL =
  'uniform float rz_capture,rz_available;uniform vec4 rz_view;uniform sampler2D rz_reflection;'#10+
  'vec3 rzEnvironment(vec3 fallback){if(rz_available<.5||rz_capture>.5)return fallback;'+
  'vec2 uv=(gl_FragCoord.xy-rz_view.xy)/rz_view.zw;'+
  'if(any(lessThan(uv,vec2(0)))||any(greaterThan(uv,vec2(1))))return fallback;'+
  'vec4 c=texture2D(rz_reflection,uv);return fallback*(1.-c.a)+c.rgb;}'#10;
implementation
uses SysUtils, CastleGL, CastleRenderOptions, CastleInternalRenderer,
  CastleRendererInternalShader, CastleRendererInternalTextureEnv, Osm3dCompositeShader;
type
  TRtxTextureNode=class(TShaderTextureNode);
  TRtxTextureResource=class(TSingleTextureResource)
  protected
    class function IsClassForTextureNode(N:TAbstractTextureNode):Boolean;override;
    procedure PrepareCore(const O:TCastleRenderOptions);override;
    procedure UnprepareCore;override;
  public
    function Bind(const UnitIndex:Cardinal):Boolean;override;
    function Enable(const UnitIndex:Cardinal;Shader:TShader;const Env:TTextureEnv):Boolean;override;
  end;
  TBinding=class
    Effect:TEffectNode;
    Capture,Available,Time:TSFFloat;
    View:TSFVec4f;
    procedure Gone(const Node:TX3DNode);
  end;
var Bindings:TList;TextureName:Cardinal;Lock:TRTLCriticalSection;Capturing:Boolean;CurrentView:TVector4;
function RtxMaterialViewport:TVector4;
begin Result:=CurrentView;end;
procedure SetRtxMaterialViewport(const View:TVector4);
begin SetRtxMaterialPass(Capturing,TextureName,View);end;
function RtxReflectionCaptureActive:Boolean;
begin Result:=Capturing;end;
function RtxReflectionsAvailable:Boolean;
begin Result:=(TextureName<>0) and not Capturing end;
class function TRtxTextureResource.IsClassForTextureNode(N:TAbstractTextureNode):Boolean;
begin Result:=N is TRtxTextureNode;end;
procedure TRtxTextureResource.PrepareCore(const O:TCastleRenderOptions);begin end;
procedure TRtxTextureResource.UnprepareCore;begin end;
function TRtxTextureResource.Bind(const UnitIndex:Cardinal):Boolean;
begin glActiveTexture(GL_TEXTURE0+UnitIndex);glBindTexture(GL_TEXTURE_2D,TextureName);Result:=True;end;
function TRtxTextureResource.Enable(const UnitIndex:Cardinal;Shader:TShader;const Env:TTextureEnv):Boolean;
begin Result:=Bind(UnitIndex);end;
procedure TBinding.Gone(const Node:TX3DNode);
begin EnterCriticalSection(Lock);try Bindings.Remove(Self);finally LeaveCriticalSection(Lock);end;Free;end;
procedure AttachRtxMaterial(Effect:TEffectNode);
var B:TBinding;Proxy:TRtxTextureNode;
begin
  B:=TBinding.Create;B.Effect:=Effect;
  B.Capture:=TSFFloat.Create(Effect,True,'rz_capture',0);Effect.AddCustomField(B.Capture);
  B.Available:=TSFFloat.Create(Effect,True,'rz_available',0);Effect.AddCustomField(B.Available);
  B.View:=TSFVec4f.Create(Effect,True,'rz_view',Vector4(0,0,1,1));Effect.AddCustomField(B.View);
  Proxy:=TRtxTextureNode.Create;
  Effect.AddCustomField(TSFNode.Create(Effect,True,'rz_reflection',[TShaderTextureNode],Proxy));
  Effect.AddDestructionNotification(@B.Gone);
  EnterCriticalSection(Lock);try Bindings.Add(B);finally LeaveCriticalSection(Lock);end;
end;
procedure AttachRtxGroundCaptureFlag(Effect:TEffectNode);
var B:TBinding;Proxy:TRtxTextureNode;
begin
  if Effect.Field('rz_ground_capture')<>nil then Exit;
  B:=TBinding.Create;B.Effect:=Effect;
  B.Capture:=TSFFloat.Create(Effect,True,'rz_ground_capture',0);Effect.AddCustomField(B.Capture);
  B.Available:=TSFFloat.Create(Effect,True,'gp_available',0);Effect.AddCustomField(B.Available);
  B.View:=TSFVec4f.Create(Effect,True,'gp_view',Vector4(0,0,1,1));Effect.AddCustomField(B.View);
  B.Time:=TSFFloat.Create(Effect,True,'gp_time',0);Effect.AddCustomField(B.Time);
  Proxy:=TRtxTextureNode.Create;
  Effect.AddCustomField(TSFNode.Create(Effect,True,'gp_reflection',[TShaderTextureNode],Proxy));
  Effect.AddDestructionNotification(@B.Gone);
  EnterCriticalSection(Lock);try Bindings.Add(B);finally LeaveCriticalSection(Lock);end;
end;
procedure SetRtxMaterialPass(Capture:Boolean;Texture:Cardinal;const View:TVector4);
var I:Integer;B:TBinding;Available,WaterTime:Single;
begin
  Capturing:=Capture;TextureName:=Texture;CurrentView:=View;Available:=Ord((Texture<>0) and not Capture);
  WaterTime:=CompositeShaderMaxClock;
  EnterCriticalSection(Lock);
  try for I:=0 to Bindings.Count-1 do begin
    B:=TBinding(Bindings[I]);
    if (B.Time<>nil) and (Capture or (Texture<>0)) and (B.Time.Value<>WaterTime) then B.Time.Send(WaterTime);
    if B.Capture.Value<>Ord(Capture) then B.Capture.Send(Ord(Capture));
    if (B.Available<>nil) and (B.Available.Value<>Available) then B.Available.Send(Available);
    if (B.View<>nil) and not TVector4.Equals(B.View.Value,View) then B.View.Send(View);
  end;finally LeaveCriticalSection(Lock);end;
end;
function IsRtxReflector(const Shape:TShape):Boolean;
var I:Integer;A:TAppearanceNode;E:TEffectNode;
begin
  Result:=False;if (Shape.Node=nil) or not (Shape.Node.Appearance is TAppearanceNode) then Exit;
  A:=TAppearanceNode(Shape.Node.Appearance);
  for I:=0 to A.FdEffects.Count-1 do begin
    if not (A.FdEffects[I] is TEffectNode) then Continue;E:=TEffectNode(A.FdEffects[I]);
    if (E.Field('rz_capture')<>nil) or (E.Field('rz_ground_capture')<>nil) then Exit(True);
  end;
end;
function IsRtxGround(const Shape:TShape):Boolean;
var I:Integer;A:TAppearanceNode;
begin
  Result:=False;if (Shape.Node=nil) or not (Shape.Node.Appearance is TAppearanceNode) then Exit;
  A:=TAppearanceNode(Shape.Node.Appearance);
  for I:=0 to A.FdEffects.Count-1 do
    if A.FdEffects[I] is TEffectNode then
      if TEffectNode(A.FdEffects[I]).Field('rz_ground_capture')<>nil then Exit(True);
end;
initialization
  InitCriticalSection(Lock);Bindings:=TList.Create;
  TTextureResource.RegisterClass(TRtxTextureResource);
end.
