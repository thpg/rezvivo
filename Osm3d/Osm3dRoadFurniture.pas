unit Osm3dRoadFurniture;
{$mode objfpc}{$H+}
interface
uses CastleVectors, X3DNodes;
const
  SIGN_CROSSING_RIGHT=0; SIGN_CROSSING_LEFT=1;
  SIGN_BUMP_WARNING=2; SIGN_BUMP=3;
  SIGN_METAL=4; SIGN_WHITE=5; SIGN_RUBBER=6; SIGN_YELLOW=7;
function RoadFurnitureUV(Cell:Integer; U,V:Single):TVector2;
procedure ApplyRoadFurnitureMaterial(Shape:TShapeNode);
implementation
uses CastleRenderOptions, Osm3dRiderShadow;
function RoadFurnitureUV(Cell:Integer; U,V:Single):TVector2;
begin
  Result:=Vector2(((Cell mod 4)*256+4+U*248)/1024,
    ((1-Cell div 4)*256+4+V*248)/512);
end;
procedure ApplyRoadFurnitureMaterial(Shape:TShapeNode);
var App:TAppearanceNode;Mat:TPhysicalMaterialNode;Tex:TImageTextureNode;
  Props:TTexturePropertiesNode;Eff:TRiderShadowGroundEffect;Frag:TEffectPartNode;
begin
  App:=TAppearanceNode.Create;Mat:=TPhysicalMaterialNode.Create;
  Mat.BaseColor:=Vector3(1,1,1);Mat.Metallic:=0;Mat.Roughness:=0.85;
  App.Material:=Mat;App.AlphaMode:=amMask;App.AlphaCutoff:=0.5;
  Tex:=TImageTextureNode.Create;
  Tex.SetUrl(['castle-data:/Osm3d/resources/textures/road_signs/road_signs.png']);
  Tex.RepeatS:=False;Tex.RepeatT:=False;
  Props:=TTexturePropertiesNode.Create;Props.GenerateMipMaps:=True;
  Props.AnisotropicDegree:=8;Tex.TextureProperties:=Props;Mat.BaseTexture:=Tex;
  { The flat markings must not cast a broad ground shadow. Pole/board geometry
    still receives the same light and shared world/rider shadow as the road. }
  App.ShadowCaster:=False;
  Eff:=TRiderShadowGroundEffect.Create;Eff.Language:=slGLSL;
  Eff.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);
  Frag:=TEffectPartNode.Create;Frag.ShaderType:=stFragment;
  Frag.Contents:=RIDER_SHADOW_GLSL+#10+
    'vec4 position_eye_to_world_space(vec4 p);'+#10+
    'vec3 direction_eye_to_world_space(vec3 d);'+#10+
    'vec3 rf_indirect;'+#10+
    'void PLUG_main_texture_apply(inout vec4 color,const vec3 n) {'+#10+
    ' float h=normalize(direction_eye_to_world_space(n)).y*0.5+0.5;'+#10+
    ' rf_indirect=color.rgb*mix(vec3(0.13,0.12,0.10),vec3(0.35,0.40,0.48),h);'+#10+
    '}'+#10+
    'void PLUG_material_occlusion(inout vec4 color) { color.rgb+=rf_indirect; }'+#10+
    'void PLUG_fragment_eye_space(const vec4 p,inout vec3 n) {'+#10+
    ' gc_riderPosition=position_eye_to_world_space(p).xyz;'+#10+
    ' gc_riderRelativePosition=position_eye_to_world_space(vec4(p.xyz,0.0)).xyz;'+#10+
    '}'+#10;
  Eff.SetParts([Frag]);Eff.SetGroundFragment(Frag);App.SetEffects([Eff]);
  Shape.Appearance:=App;
end;
end.
