unit Osm3dManholeRender;
{$mode objfpc}{$H+}
interface
uses Osm3dManholeData, X3DNodes;
function BuildManholeNode(const Points:TManholeArray; EastScale:Single):TAbstractChildNode;
implementation
uses SysUtils, Math, CastleVectors, CastleRenderOptions, Osm3dRiderShadow;
const BASE='castle-data:/Osm3d/resources/textures/Manholes/';
function Texture(const S:string):TImageTextureNode;
var P:TTexturePropertiesNode;
begin
  Result:=TImageTextureNode.Create;Result.SetUrl([BASE+S+'.png']);
  Result.RepeatS:=False;Result.RepeatT:=False;
  P:=TTexturePropertiesNode.Create;P.GenerateMipMaps:=True;
  P.AnisotropicDegree:=8;Result.TextureProperties:=P;
end;
function BuildManholeNode(const Points:TManholeArray; EastScale:Single):TAbstractChildNode;
var
  Shape:TShapeNode;Geo:TIndexedFaceSetNode;Coord:TCoordinateNode;
  Normal:TNormalNode;UV:TTextureCoordinateNode;App:TAppearanceNode;
  Mat:TPhysicalMaterialNode;Eff:TRiderShadowGroundEffect;Frag:TEffectPartNode;
  I,J,First:Integer;M:TManhole;U,V,P,N:TVector3;S,T,TX,TY:Single;
begin
  Result:=nil;if Length(Points)=0 then Exit;
  Shape:=TShapeNode.Create('Manholes');Geo:=TIndexedFaceSetNode.Create;
  Shape.Geometry:=Geo;
  Coord:=TCoordinateNode.Create;Normal:=TNormalNode.Create;UV:=TTextureCoordinateNode.Create;
  Geo.Coord:=Coord;Geo.Normal:=Normal;Geo.TexCoord:=UV;
  Geo.Solid:=True;Geo.NormalPerVertex:=True;
  for I:=0 to High(Points) do begin
    M:=Points[I];if (M.Kind<0)or(M.Kind>=MANHOLE_COUNT) then Continue;
    ManholeAxes(M,U,V);U:=U*(MANHOLE_SIZES[M.Kind].X*0.5);
    V:=V*(MANHOLE_SIZES[M.Kind].Y*0.5);
    N:=Vector3(M.Normal.X/EastScale,M.Normal.Y,M.Normal.Z).Normalize;
    First:=Coord.FdPoint.Count;
    for J:=0 to 3 do begin
      case J of
        0:begin S:=0;T:=0 end;1:begin S:=0;T:=1 end;
        2:begin S:=1;T:=1 end;else begin S:=1;T:=0 end;
      end;
      P:=M.Position+U*(S*2-1)+V*(T*2-1);P.X:=P.X*EastScale;
      Coord.FdPoint.Items.Add(P);Normal.FdVector.Items.Add(N);
      TX:=((M.Kind mod 4)*256+4+S*248)/1024;
      TY:=((M.Kind div 4)*256+4+T*248)/1024;
      UV.FdPoint.Items.Add(Vector2(TX,TY));Geo.FdCoordIndex.Items.Add(First+J);
    end;
    Geo.FdCoordIndex.Items.Add(-1);
  end;
  App:=TAppearanceNode.Create;Mat:=TPhysicalMaterialNode.Create;
  Mat.BaseColor:=Vector3(1,1,1);Mat.Metallic:=1;Mat.Roughness:=1;
  Mat.BaseTexture:=Texture('manholes_color');
  Mat.MetallicRoughnessTexture:=Texture('manholes_orm');
  App.Material:=Mat;App.AlphaMode:=amMask;App.AlphaCutoff:=0.5;
  App.ShadowCaster:=False;
  { Appearance normal map selects the per-material height scale; a Material
    NormalTexture would instead use the scene's global parallax scale. }
  App.NormalMap:=Texture('manholes_normal_height');
  App.HeightMapScale:=0.002; { atlas UV: shallow millimetre relief }
  Shape.Appearance:=App;
  Eff:=TRiderShadowGroundEffect.Create;Eff.Language:=slGLSL;
  Eff.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);
  Frag:=TEffectPartNode.Create;Frag.ShaderType:=stFragment;
  Frag.Contents:=RIDER_SHADOW_GLSL+#10+
    'vec4 position_eye_to_world_space(vec4 position_eye);'+#10+
    'vec3 direction_eye_to_world_space(vec3 direction_eye);'+#10+
    'vec3 mh_normal, mh_view, mh_albedo;'+#10+
    'float mh_metal, mh_rough;'+#10+
    'void PLUG_fragment_eye_space(const vec4 p, inout vec3 n) {'+#10+
    '  if (dot(p.xyz,p.xyz)>22500.0) discard;'+#10+
    '  gc_riderPosition=position_eye_to_world_space(p).xyz;'+#10+
    '  gc_riderRelativePosition=position_eye_to_world_space(vec4(p.xyz,0.0)).xyz;'+#10+
    '  mh_view=normalize(direction_eye_to_world_space(-p.xyz));'+#10+
    '}'+#10+
    { Capture CGE's already decoded base colour, mapped normal and ORM values,
      after the built-in texture plugs. PBR ignores light AmbientIntensity:
      direct lights alone leave a rough metal without its broad sky reflection.
      This cheap outdoor hemisphere follows the world's lighting conventions,
      adds no texture reads, and is attenuated by the shared shadow receiver. }
    'void PLUG_main_texture_apply(inout vec4 color, const vec3 normal) {'+#10+
    '  mh_albedo=color.rgb;'+#10+
    '  mh_normal=normalize(direction_eye_to_world_space(normal));'+#10+
    '}'+#10+
    'void PLUG_material_metallic_roughness(inout float metal, inout float rough) {'+#10+
    '  mh_metal=clamp(metal,0.0,1.0); mh_rough=clamp(rough,0.0,1.0);'+#10+
    '}'+#10+
    'void PLUG_material_occlusion(inout vec4 color) {'+#10+
    '  vec3 sky=vec3(0.45,0.52,0.62), ground=vec3(0.13,0.12,0.10);'+#10+
    '  vec3 diffuse=mix(ground,sky,mh_normal.y*0.5+0.5);'+#10+
    '  vec3 reflected=reflect(-mh_view,mh_normal);'+#10+
    '  float h=mix(smoothstep(-0.3,0.6,reflected.y),0.5,mh_rough*mh_rough);'+#10+
    '  vec3 environment=mix(ground,sky,h);'+#10+
    '  color.rgb+=mh_albedo*diffuse*(1.0-mh_metal)'+#10+
    '    +mix(vec3(0.04),mh_albedo,mh_metal)*environment;'+#10+
    '}'+#10;
  Eff.SetParts([Frag]);Eff.SetGroundFragment(Frag);App.SetEffects([Eff]);
  Result:=Shape;
end;
end.
