unit AvatarFabricMaterial;
{$mode objfpc}{$H+}
interface
uses X3DNodes;

{ One material path for the editor's simulated cloth and the game's GPU skin.
  Pattern coordinates are immutable, so cached animation cannot make it swim. }
function ApplyAvatarFabric(Shape:TShapeNode;const Preset:string):Boolean;

implementation
uses SysUtils,Math,CastleVectors,CastleUtils,X3DFields,CastleRenderOptions,
  RiderShaderSharing,RenderComplexity;
const
  FabricVS=
    'attribute vec2 avatarFabricUV; varying vec2 afUV;'+#10+
    'void PLUG_vertex_eye_space(const vec4 p,const vec3 n){afUV=avatarFabricUV;}';
  FabricFS=
    'varying vec2 afUV; uniform vec4 afProfile,afFinish; uniform float rz_complexity;'+#10+
    'float afThread=0.0,afYarn=0.0,afFleck=0.0;'+#10+
    'float afHash(vec2 p){vec3 q=fract(vec3(p.xyx)*.1031);q+=dot(q,q.yzx+33.33);return fract((q.x+q.y)*q.z);}'+#10+
    'float afNoise(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.0-2.0*f);'+#10+
    'return mix(mix(afHash(i),afHash(i+vec2(1,0)),f.x),mix(afHash(i+vec2(0,1)),afHash(i+vec2(1,1)),f.x),f.y)*2.0-1.0;}'+#10+
    'float afWave(float q){float f=fwidth(q);return cos(6.2831853*q)*exp2(-8.0*f*f);}'+#10+
    'void PLUG_fragment_eye_space(const vec4 p,inout vec3 n){'+#10+
    ' if(rz_complexity<.5)return;'+#10+
    ' vec2 q=afUV/afProfile.x;float warp=afWave(q.x),weft=afWave(q.y);'+#10+
    ' if(afProfile.w<.5)afThread=(warp+weft)*.42+warp*weft*.16;'+#10+
    ' else if(afProfile.w<1.5)afThread=.72*afWave((q.x+q.y)*.5)+.18*warp+.10*weft;'+#10+
    ' else if(afProfile.w<2.5)afThread=.65*warp+.35*afWave(q.y+.18*warp);'+#10+
    ' else afThread=(warp+weft)*.4+warp*weft*.2;'+#10+
    ' afYarn=.6*afWave(q.x/4.7)+.4*afWave((q.y+q.x*.17)/5.9);'+#10+
    ' vec2 grain=afUV/afFinish.x;float footprint=max(fwidth(grain.x),fwidth(grain.y));'+#10+
    ' afFleck=afNoise(grain)*exp2(-3.0*footprint*footprint);'+#10+
    // Reinforcement threads remain only in ripstop, at their physical scale.
    ' if(afProfile.w>2.5){float x=.5+.5*afWave(afUV.x/.006),y=.5+.5*afWave(afUV.y/.006);'+#10+
    ' afYarn=(x*x*x*x+y*y*y*y-.55)*.7;}'+#10+
    ' if(rz_complexity<1.5)return;'+#10+
    ' float h=afProfile.y*(afThread+.45*afYarn+.32*afFleck);'+#10+
    ' vec3 dx=dFdx(p.xyz),dy=dFdy(p.xyz),N=normalize(n);'+#10+
    ' vec3 r1=cross(dy,N),r2=cross(N,dx);float det=dot(dx,r1);'+#10+
    ' if(det*det>1e-12*dot(dx,dx)*dot(dy,dy)){'+#10+
    ' vec3 grad=(r1*dFdx(h)+r2*dFdy(h))/det;grad*=min(1.0,.38/max(length(grad),1e-8));n=normalize(N-grad);}'+#10+
    '}'+#10+
    'void PLUG_main_texture_apply(inout vec4 c,const vec3 n){'+#10+
    ' c.rgb*=1.0+afFinish.y*afThread+afFinish.z*afYarn+afFinish.w*afFleck;'+#10+
    '}'+#10+
    'void PLUG_material_metallic_roughness(inout float m,inout float r){'+#10+
    ' m=0.0;r=clamp(afProfile.z+.035*afThread+.025*afYarn+.03*afFleck,.38,.98);'+#10+
    '}';

function FabricProfile(const Preset:string;out Profile,Finish:TVector4):Boolean;
begin
  Result:=True;
  { metres: thread spacing / relief. Finish: fleck scale / three contrasts.
    Slightly legible yarn bundles sit above the subpixel thread detail. }
  Finish:=Vector4(0.005,0.09,0.045,0.055);
  if Preset='jacket'then Profile:=Vector4(0.0016,0.00009,0.68,1)
  else if Preset='loose_jacket'then begin
    Profile:=Vector4(0.0020,0.00012,0.83,0);Finish:=Vector4(0.006,0.12,0.055,0.07);
  end else if Preset='coat'then begin
    Profile:=Vector4(0.0022,0.00016,0.92,1);Finish:=Vector4(0.0035,0.09,0.04,0.20);
  end else if Preset='raincoat'then begin
    Profile:=Vector4(0.0010,0.00004,0.49,3);Finish:=Vector4(0.008,0.055,0.055,0.022);
  end else if Preset='tshirt'then begin
    Profile:=Vector4(0.0014,0.000055,0.84,2);Finish:=Vector4(0.004,0.075,0.035,0.045);
  end else if Preset='sweatshirt'then begin
    Profile:=Vector4(0.0020,0.00010,0.91,2);Finish:=Vector4(0.004,0.09,0.05,0.10);
  end else if Preset='jeans'then begin
    Profile:=Vector4(0.0012,0.000065,0.88,1);Finish:=Vector4(0.0035,0.19,0.035,0.065);
  end else if Preset='trousers'then Profile:=Vector4(0.0016,0.000075,0.78,1)
  else if Preset='beanie'then begin
    Profile:=Vector4(0.0032,0.00019,0.93,2);Finish:=Vector4(0.005,0.14,0.05,0.10);
  end else if(Preset='cap')or(Preset='bucket')then Profile:=Vector4(0.0018,0.000085,0.82,0)
  else Result:=False;
end;

function ApplyAvatarFabric(Shape:TShapeNode;const Preset:string):Boolean;
var App:TAppearanceNode;Mat:TPhysicalMaterialNode;Geo:TAbstractComposedGeometryNode;
  Coord:TCoordinateNode;UV:TTextureCoordinateNode;UVNode:TX3DNode;
  Attr:TFloatVertexAttributeNode;Effect:TEffectNode;V,F:TEffectPartNode;
  Profile,Finish:TVector4;I,J,A,B:Integer;P:TVector3;T:TVector2;
  EdgeScales:TSingleList;WorldLength,UVLength,Scale:Single;
begin
  Result:=False;
  if not FabricProfile(Preset,Profile,Finish)or
    not(Shape.Appearance is TAppearanceNode)or
    not(Shape.Appearance.Material is TPhysicalMaterialNode)or
    not(Shape.Geometry is TAbstractComposedGeometryNode)then Exit;
  App:=TAppearanceNode(Shape.Appearance);Mat:=TPhysicalMaterialNode(App.Material);
  Geo:=TAbstractComposedGeometryNode(Shape.Geometry);
  if not(Geo.Coord is TCoordinateNode)then Exit;
  Coord:=TCoordinateNode(Geo.Coord);if Coord.FdPoint.Count=0 then Exit;
  Result:=True;
  Attr:=nil;
  for I:=0 to Geo.FdAttrib.Count-1 do
    if(Geo.FdAttrib[I] is TFloatVertexAttributeNode)and
      (TFloatVertexAttributeNode(Geo.FdAttrib[I]).NameField='avatarFabricUV')then
      Attr:=TFloatVertexAttributeNode(Geo.FdAttrib[I]);
  if Attr=nil then begin
    UVNode:=Geo.TexCoord;
    if(UVNode is TMultiTextureCoordinateNode)and(TMultiTextureCoordinateNode(UVNode).FdTexCoord.Count>0)then
      UVNode:=TMultiTextureCoordinateNode(UVNode).FdTexCoord[0];
    UV:=nil;if UVNode is TTextureCoordinateNode then UV:=TTextureCoordinateNode(UVNode);
    if(UV<>nil)and(UV.FdPoint.Count<>Coord.FdPoint.Count)then UV:=nil;
    Scale:=1;
    if(UV<>nil)and(Geo is TIndexedTriangleSetNode)then begin
      { Atlas cuts on tiny folded hems can span several UV islands. Their
        squared jumps dominated the old mean, enlarging yarn into stripes.
        Use the median scale of actual panel edges instead. }
      EdgeScales:=TSingleList.Create;
      try
        for I:=0 to TIndexedTriangleSetNode(Geo).FdIndex.Count div 3-1 do
          for J:=0 to 2 do begin
            A:=TIndexedTriangleSetNode(Geo).FdIndex.Items[I*3+J];
            B:=TIndexedTriangleSetNode(Geo).FdIndex.Items[I*3+(J+1)mod 3];
            P:=Coord.FdPoint.Items[A]-Coord.FdPoint.Items[B];T:=UV.FdPoint.Items[A]-UV.FdPoint.Items[B];
            WorldLength:=P.Length;UVLength:=T.Length;
            if(WorldLength>0.005)and(UVLength>1e-6)then EdgeScales.Add(WorldLength/UVLength);
          end;
        if EdgeScales.Count>0 then begin EdgeScales.Sort;Scale:=EdgeScales[EdgeScales.Count div 2] end;
      finally EdgeScales.Free end;
    end;
    Attr:=TFloatVertexAttributeNode.Create;Attr.NameField:='avatarFabricUV';Attr.NumComponents:=2;
    for I:=0 to Coord.FdPoint.Count-1 do begin
      if UV<>nil then T:=UV.FdPoint.Items[I]*Scale
      else begin P:=Coord.FdPoint.Items[I];T:=Vector2(P.X,P.Y) end;
      Attr.FdValue.Items.Add(T.X);Attr.FdValue.Items.Add(T.Y);
    end;
    Geo.FdAttrib.Add(Attr);
  end;
  { Shared appearances get one shader; every primitive keeps its own UVs. }
  for I:=0 to App.FdEffects.Count-1 do
    if App.FdEffects[I].X3DName='AvatarFabricMaterial'then Exit;
  Mat.Metallic:=0;Mat.Roughness:=Profile.Z;
  Effect:=TEffectNode.Create('AvatarFabricMaterial');Effect.Language:=slGLSL;
  Effect.UniformMissing:=umIgnore;AttachRenderComplexity(Effect,rdRider);
  Effect.AddCustomField(TSFVec4f.Create(Effect,True,'afProfile',Profile));
  Effect.AddCustomField(TSFVec4f.Create(Effect,True,'afFinish',Finish));
  V:=TEffectPartNode.Create;V.ShaderType:=stVertex;V.Contents:=FabricVS;
  F:=TEffectPartNode.Create;F.ShaderType:=stFragment;F.Contents:=FabricFS;
  Effect.SetParts([V,F]);ShareRiderEffect(Effect);App.FdEffects.Add(Effect);
end;
end.
