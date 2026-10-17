unit Osm3dRtxMaterials;
{$ifdef ANDROID}{$define OpenGLES}{$endif}
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
function RtxMaterialRevision:QWord;
function RtxReflectionCaptureActive:Boolean;
function RtxReflectionsAvailable:Boolean;
const RTX_MATERIAL_GLSL =
  'uniform float rz_capture,rz_available;uniform vec4 rz_view;uniform sampler2D rz_reflection;'#10+
  'vec3 rzEnvironment(vec3 fallback){if(rz_available<.5||rz_capture>.5)return fallback;'+
  'vec2 uv=(gl_FragCoord.xy-rz_view.xy)/rz_view.zw;'+
  'if(any(lessThan(uv,vec2(0)))||any(greaterThan(uv,vec2(1))))return fallback;'+
  'vec4 c=texture2D(rz_reflection,uv);return fallback*(1.-c.a)+c.rgb;}'#10;
implementation
uses SysUtils, Generics.Collections, {$ifdef OpenGLES}CastleGLES{$else}CastleGL{$endif}, CastleRenderOptions, CastleInternalRenderer,
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
    procedure Sync(const ACapture:Boolean;const AAvailable,WaterTime:Single;const AView:TVector4);
  end;
  TMaterialClass = class
    Appearance:TAppearanceNode;
    Revision:QWord;
    Effects:array of TX3DNode;
    Reflector,Ground:Boolean;
    procedure Gone(const Node:TX3DNode);
    procedure Refresh;
  end;
  TMaterialClasses=specialize TObjectDictionary<TAppearanceNode,TMaterialClass>;
var Bindings:TList;TextureName:Cardinal;Lock:TRTLCriticalSection;Capturing:Boolean;CurrentView:TVector4;
  BindingRevision:QWord=1;
  AppliedRevision:QWord;
  AppliedTime:Single;
  PassValid:Boolean;
  UsePassTuple:Boolean;
  MaterialClasses:TMaterialClasses;
function RtxMaterialRevision:QWord;
begin Result:=BindingRevision end;
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
begin EnterCriticalSection(Lock);try Bindings.Remove(Self);Inc(BindingRevision);finally LeaveCriticalSection(Lock);end;Free;end;
procedure AttachRtxMaterial(Effect:TEffectNode);
var B:TBinding;Proxy:TRtxTextureNode;
begin
  B:=TBinding.Create;B.Effect:=Effect;
  B.Capture:=TSFFloat.Create(Effect,True,'rz_capture',Ord(Capturing));Effect.AddCustomField(B.Capture);
  B.Available:=TSFFloat.Create(Effect,True,'rz_available',Ord((TextureName<>0) and not Capturing));Effect.AddCustomField(B.Available);
  B.View:=TSFVec4f.Create(Effect,True,'rz_view',CurrentView);Effect.AddCustomField(B.View);
  Proxy:=TRtxTextureNode.Create;
  Effect.AddCustomField(TSFNode.Create(Effect,True,'rz_reflection',[TShaderTextureNode],Proxy));
  Effect.AddDestructionNotification(@B.Gone);
  EnterCriticalSection(Lock);try Bindings.Add(B);Inc(BindingRevision);finally LeaveCriticalSection(Lock);end;
end;
procedure AttachRtxGroundCaptureFlag(Effect:TEffectNode);
var B:TBinding;Proxy:TRtxTextureNode;
begin
  if Effect.Field('rz_ground_capture')<>nil then Exit;
  B:=TBinding.Create;B.Effect:=Effect;
  B.Capture:=TSFFloat.Create(Effect,True,'rz_ground_capture',Ord(Capturing));Effect.AddCustomField(B.Capture);
  B.Available:=TSFFloat.Create(Effect,True,'gp_available',Ord((TextureName<>0) and not Capturing));Effect.AddCustomField(B.Available);
  B.View:=TSFVec4f.Create(Effect,True,'gp_view',CurrentView);Effect.AddCustomField(B.View);
  B.Time:=TSFFloat.Create(Effect,True,'gp_time',CompositeShaderMaxClock);Effect.AddCustomField(B.Time);
  Proxy:=TRtxTextureNode.Create;
  Effect.AddCustomField(TSFNode.Create(Effect,True,'gp_reflection',[TShaderTextureNode],Proxy));
  Effect.AddDestructionNotification(@B.Gone);
  EnterCriticalSection(Lock);try Bindings.Add(B);Inc(BindingRevision);finally LeaveCriticalSection(Lock);end;
end;
procedure TBinding.Sync(const ACapture:Boolean;const AAvailable,WaterTime:Single;const AView:TVector4);
begin
  if (Time<>nil) and (ACapture or (TextureName<>0)) and (Time.Value<>WaterTime) then Time.Send(WaterTime);
  if Self.Capture.Value<>Ord(ACapture) then Self.Capture.Send(Ord(ACapture));
  if (Self.Available<>nil) and (Self.Available.Value<>AAvailable) then Self.Available.Send(AAvailable);
  if (Self.View<>nil) and not TVector4.Equals(Self.View.Value,AView) then Self.View.Send(AView);
end;
procedure SetRtxMaterialPass(Capture:Boolean;Texture:Cardinal;const View:TVector4);
var I:Integer;Available,WaterTime:Single;
begin
  WaterTime:=CompositeShaderMaxClock;
  EnterCriticalSection(Lock);
  try
    if UsePassTuple and PassValid and (AppliedRevision=BindingRevision) and
       (Capture=Capturing) and (Texture=TextureName) and
       CompareMem(@View,@CurrentView,SizeOf(View)) and
       ((not Capture and (Texture=0)) or (WaterTime=AppliedTime)) then Exit;
    Capturing:=Capture;TextureName:=Texture;CurrentView:=View;
    Available:=Ord((Texture<>0) and not Capture);
    for I:=0 to Bindings.Count-1 do TBinding(Bindings[I]).Sync(Capture,Available,WaterTime,View);
    AppliedTime:=WaterTime;AppliedRevision:=BindingRevision;PassValid:=True;
  finally LeaveCriticalSection(Lock);end;
end;
procedure TMaterialClass.Gone(const Node:TX3DNode);
begin
  MaterialClasses.Remove(Appearance);
end;
procedure TMaterialClass.Refresh;
var I:Integer;E:TEffectNode;Changed:Boolean;
begin
  Changed:=(Revision<>BindingRevision) or (Length(Effects)<>Appearance.FdEffects.Count);
  if not Changed then for I:=0 to High(Effects) do
    if Effects[I]<>Appearance.FdEffects[I] then begin Changed:=True;Break end;
  if not Changed then Exit;
  SetLength(Effects,Appearance.FdEffects.Count);Reflector:=False;Ground:=False;
  for I:=0 to High(Effects) do begin
    Effects[I]:=Appearance.FdEffects[I];
    if not (Effects[I] is TEffectNode) then Continue;
    E:=TEffectNode(Effects[I]);
    Ground:=Ground or (E.Field('rz_ground_capture')<>nil);
    Reflector:=Reflector or Ground or (E.Field('rz_capture')<>nil);
  end;
  Revision:=BindingRevision;
end;
function MaterialClass(const Shape:TShape):TMaterialClass;
var A:TAppearanceNode;
begin
  Result:=nil;
  if (Shape.Node=nil) or not (Shape.Node.Appearance is TAppearanceNode) then Exit;
  A:=TAppearanceNode(Shape.Node.Appearance);
  if not MaterialClasses.TryGetValue(A,Result) then begin
    Result:=TMaterialClass.Create;Result.Appearance:=A;
    A.AddDestructionNotification(@Result.Gone);MaterialClasses.Add(A,Result);
  end;
  Result.Refresh;
end;
function IsRtxReflector(const Shape:TShape):Boolean;
var M:TMaterialClass;
begin M:=MaterialClass(Shape);Result:=(M<>nil) and M.Reflector end;
function IsRtxGround(const Shape:TShape):Boolean;
var M:TMaterialClass;
begin M:=MaterialClass(Shape);Result:=(M<>nil) and M.Ground end;
procedure ReleaseRegistries;
var I:Integer;B:TBinding;M:TMaterialClass;
begin
  for M in MaterialClasses.Values do M.Appearance.RemoveDestructionNotification(@M.Gone);
  FreeAndNil(MaterialClasses);
  for I:=Bindings.Count-1 downto 0 do begin
    B:=TBinding(Bindings[I]);B.Effect.RemoveDestructionNotification(@B.Gone);B.Free;
  end;
  FreeAndNil(Bindings);DoneCriticalSection(Lock);
end;
initialization
  UsePassTuple:=GetEnvironmentVariable('REZVIVO_LEGACY_RTX_MATERIAL_TUPLE')<>'1';
  InitCriticalSection(Lock);Bindings:=TList.Create;
  CurrentView:=Vector4(0,0,1,1);
  MaterialClasses:=TMaterialClasses.Create([doOwnsValues]);
  TTextureResource.RegisterClass(TRtxTextureResource);
finalization
  ReleaseRegistries;
end.
