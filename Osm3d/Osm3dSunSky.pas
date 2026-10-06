unit Osm3dSunSky;
{$mode objfpc}{$H+}
interface
uses X3DNodes, X3DFields, CastleVectors;
const
  SUN_DISC_GLSL =
    'float rzSunDisc(vec3 ray,vec3 sun){float a=dot(normalize(ray),normalize(sun));'+#10+
    ' float w=max(fwidth(a),0.000001);return smoothstep(0.9999892-w,0.9999892+w,a)*min(1.,0.0000108/w);}' + #10;
function CreateSunSkyEffect:TEffectNode;
procedure SetSkySun(const LightDirection:TVector3;Visible:Boolean=True);
implementation
uses Classes,SysUtils,CastleRenderOptions;
type
  TSunSkyEffect=class(TEffectNode)
  public
    Direction:TSFVec3f;
    Visibility:TSFFloat;
    constructor Create(const AName:string='';const ABaseUrl:string='');override;
    destructor Destroy;override;
  end;
var Effects:TList;
constructor TSunSkyEffect.Create(const AName:string;const ABaseUrl:string);
var P,V:TEffectPartNode;
begin
  inherited;Language:=slGLSL;
  SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);
  Direction:=TSFVec3f.Create(Self,True,'rz_sky_sun',Vector3(0.4,0.7,-0.5));AddCustomField(Direction);
  Visibility:=TSFFloat.Create(Self,True,'rz_sky_visible',1);AddCustomField(Visibility);
  V:=TEffectPartNode.Create;V.ShaderType:=stVertex;
  V.Contents:='vec4 position_eye_to_world_space(vec4 position_eye);'+#10+
    'varying vec3 rz_sky_ray;'+#10+
    'void PLUG_vertex_eye_space(const vec4 vertex_eye,const vec3 normal_eye){'+#10+
    ' rz_sky_ray=position_eye_to_world_space(vec4(vertex_eye.xyz,0.0)).xyz;}';
  P:=TEffectPartNode.Create;P.ShaderType:=stFragment;
  P.Contents:=SUN_DISC_GLSL+
    'uniform vec3 rz_sky_sun;uniform float rz_sky_visible;varying vec3 rz_sky_ray;'+#10+
    'void PLUG_fragment_end(inout vec4 color){vec3 L=normalize(rz_sky_sun);'+#10+
    ' float visible=rz_sky_visible*smoothstep(-.015,.01,L.y);'+#10+
    ' float disc=rzSunDisc(rz_sky_ray,L)*visible;'+#10+
    ' float halo=pow(max(dot(normalize(rz_sky_ray),L),0.),180.)*.10*visible;'+#10+
    ' vec3 tint=mix(vec3(1,.57,.27),vec3(1,.98,.91),smoothstep(0.,.4,L.y));'+#10+
    ' color.rgb=mix(color.rgb,tint,clamp(disc+halo,0.,1.));}';
  SetParts([V,P]);Effects.Add(Self);
end;
destructor TSunSkyEffect.Destroy;
begin if Effects<>nil then Effects.Remove(Self);inherited;end;
function CreateSunSkyEffect:TEffectNode;
begin Result:=TSunSkyEffect.Create;end;
procedure SetSkySun(const LightDirection:TVector3;Visible:Boolean);
var I:Integer;E:TSunSkyEffect;Toward:TVector3;
begin
  if Effects=nil then Exit;
  Toward:=-LightDirection;if Toward.Length<1e-6 then Visible:=False else Toward:=Toward.Normalize;
  for I:=0 to Effects.Count-1 do begin
    E:=TSunSkyEffect(Effects[I]);E.Direction.Send(Toward);E.Visibility.Send(Ord(Visible));
  end;
end;
initialization Effects:=TList.Create;
finalization FreeAndNil(Effects);
end.
