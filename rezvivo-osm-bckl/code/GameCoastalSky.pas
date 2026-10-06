unit GameCoastalSky;
{$mode objfpc}{$H+}
interface
uses Classes,CastleScene;
{ Static sky: six baked faces share one direction-space cloud field.
  No animation, runtime cloud generation, or camera-position dependence. }
function CreateCoastalSky(Owner:TComponent):TCastleBackground;
implementation
uses CastleVectors,X3DNodes,CastleRenderOptions,Osm3dSunSky;
function CreateCoastalSky(Owner:TComponent):TCastleBackground;
const Base='castle-data:/sky/coastal-clear/';
var E:TEffectNode;P:TEffectPartNode;
begin
  Result:=TCastleBackground.Create(Owner);
  Result.Name:='CoastalClearSky';
  Result.SkyEquatorColor:=Vector3(0.52,0.68,0.82);
  Result.TextureNegativeZ:=Base+'back.png';
  Result.TexturePositiveZ:=Base+'front.png';
  Result.TextureNegativeX:=Base+'left.png';
  Result.TexturePositiveX:=Base+'right.png';
  Result.TextureNegativeY:=Base+'bottom.png';
  Result.TexturePositiveY:=Base+'top.png';
  { These are display-referred sky colours, not HDR material radiance.
    CGE shares the viewport renderer with the background: its material tone
    mapper otherwise greys out clouds and shifts blue towards green. }
  E:=TEffectNode.Create;E.Language:=slGLSL;
  P:=TEffectPartNode.Create;P.ShaderType:=stFragment;
  P.Contents:='vec4 coastal_authored_color;'+#10+
    'void PLUG_fragment_modify(inout vec4 c) { coastal_authored_color=c; }'+#10+
    'void PLUG_fragment_end(inout vec4 c) {'+#10+
    ' c=coastal_authored_color;'+#10+
    '#ifdef CASTLE_GAMMA_CORRECTION'+#10+
    ' c.rgb=pow(max(c.rgb,vec3(0.0)),vec3(1.0/2.2));'+#10+
    '#endif'+#10+'}';
  E.SetParts([P]);Result.SetEffects([E,CreateSunSkyEffect]);
end;
end.
