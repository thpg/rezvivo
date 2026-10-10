unit RiderFabricShader;
{$mode objfpc}{$H+}
interface
uses RiderShaderSharing, X3DNodes, X3DFields, CastleVectors;
type
  TRiderFabric = class
  private
    FReachFields: array of TSFVec2f;
    FBreathFields:array of TSFFloat;
    FPreviousReach: TVector2;
    FScale: Single;
    procedure Visit(Node:TX3DNode);
  public
    constructor Create(Root:TX3DNode;Height:Single);
    procedure Update(BreathPhase:Double=0;BreathLoad:Single=0;
      ShoulderLeft:Single=0;ShoulderRight:Single=0);
  end;
{ Attach once, before GPU skinning. Runtime-only material changes. }
procedure ApplyRiderFabric(Root: TX3DNode);

implementation
uses RenderComplexity, SysUtils, Math, CastleRenderOptions,RiderSurfaceMotion;
const
  FabricVS =
    'attribute vec3 riderFabricRest;' + #10 +
    'attribute vec2 riderFabricUV;' + #10 +
    'attribute vec3 riderFabricMetric;' + #10 + '#ifndef GL_ES' + #10 + 'uniform mat4 castle_ModelViewMatrix;' + #10 + '#endif' + #10 + '' + #10 +
    'varying vec2 rfUV;' + #10 +
    'varying vec3 rfPosition;' + #10 +
    'varying vec3 rfRestMetric;' + #10 +
    'void PLUG_vertex_eye_space(const vec4 v, const vec3 n) {' + #10 +
    '  rfPosition=riderFabricRest;rfUV=riderFabricUV;' + #10 +
    '  rfRestMetric=mat3(castle_ModelViewMatrix)*riderFabricMetric;' + #10 +
    '}';
  FabricFS =
    'uniform float rz_complexity;' + #10 +
    'varying vec3 rfPosition;' + #10 +
    'varying vec3 rfRestMetric;' + #10 +
    'varying vec2 rfUV;uniform vec2 rfReach;uniform float rfRegion;' + #10 +
    'uniform vec4 rfProfile; // spacing, height, roughness, weave kind' + #10 +
    'vec3 rfTangent=vec3(0.0);float rfRoughness=0.6;' + #10 +
    'float rfDetail=0.0,rfMeso=0.0,rfBibsPattern=0.0,rfSeam=0.0;' + #10 +
    'float rfBell(float x){return exp2(-1.442695*x*x);}' + #10 +
    'float rfFold(float phase) {' + #10 +
    '  float footprint=fwidth(phase);' + #10 +
    '  return sin(phase)*exp2(-0.35*footprint*footprint);' + #10 +
    '}' + #10 +
    'float rfRidge(float d,float width){' + #10 +
    '  float w=sqrt(width*width+fwidth(d)*fwidth(d));' + #10 +
    '  return rfBell(d/w)*width/w;' + #10 +
    '}' + #10 +
    'float rfWeave(vec2 p) {' + #10 +
    '  vec2 q=p/rfProfile.x;' + #10 +
    '  vec2 fade=exp2(-10.0*fwidth(q)*fwidth(q));' + #10 +
    '  vec2 wave=sin(6.2831853*q)*fade;' + #10 +
    '  if(rfProfile.w<0.5) return 0.5*(wave.x+wave.y);' + #10 +
    '  if(rfProfile.w<1.5) return wave.x*(0.7+0.3*wave.y);' + #10 +
    '  if(rfProfile.w<2.5) return wave.x*0.85+wave.y*0.15;' + #10 +
    '  return (wave.x+wave.y+wave.x*wave.y)*0.33;' + #10 +
    '}' + #10 +
    'void PLUG_fragment_eye_space(const vec4 v, inout vec3 n) {' + #10 +
    '  if(rz_complexity<0.5)return;' + #10 +
    '  if(rz_complexity<1.5){rfDetail=rfWeave(rfUV);return;}' + #10 +
    // Generalized metric eigenvalues give in-plane stretch without a CPU
    // cloth solve. The rest metric carries the same world/body scale; camera
    // rotation and rigid limb motion cannot create compression wrinkles.
    '  vec3 dx=dFdx(v.xyz),dy=dFdy(v.xyz),rx=dFdx(rfRestMetric),ry=dFdy(rfRestMetric);' + #10 +
    '  float e=dot(rx,rx),f=dot(rx,ry),g=dot(ry,ry),area=e*g-f*f;' + #10 +
    '  float compression=0.0;' + #10 +
    '  if(area>1e-8*e*g && e*g>1e-24){' + #10 +
    '    float E=dot(dx,dx),F=dot(dx,dy),G=dot(dy,dy);' + #10 +
    '    float trace=(E*g+G*e-2.0*F*f)/area;' + #10 +
    '    float determinant=max(E*G-F*F,0.0)/area;' + #10 +
    '    float stretch=sqrt(max(0.5*(trace-sqrt(max(trace*trace-4.0*determinant,0.0))),0.0));' + #10 +
    '    compression=smoothstep(0.025,0.22,1.0-stretch);' + #10 +
    '  }' + #10 +
    '  rfDetail=rfWeave(rfUV);' + #10 +
    '  float h=rfDetail*rfProfile.y;' + #10 +
    '  vec3 p=rfPosition;float fold=0.0,compressedFold=0.0;float ax=abs(p.x);' + #10 +
    '  float back=1.0-smoothstep(-0.115,-0.055,p.z);' + #10 +
    // The next visible scale belongs to yarn bundles in the panel UVs.
    // A body-space product of sine waves painted centimetre-wide cloudy
    // patches onto the bibs, unrelated to the fabric construction.
    '  vec2 yarn=rfUV/(rfProfile.x*3.7);' + #10 +
    '  rfMeso=0.6*rfFold(6.2831853*yarn.x)+0.4*rfFold(6.2831853*yarn.y+0.7);' + #10 +
    '  if(rfRegion<0.5){' + #10 +
    '    float belly=smoothstep(1.015,1.065,p.y)*(1.0-smoothstep(1.20,1.28,p.y))*smoothstep(0.015,0.075,p.z);' + #10 +
    '    float frontLine=p.y+0.18*ax+0.006*sin(p.x*37.0);' + #10 +
    '    float compressionRidges=rfRidge(frontLine-1.087,0.009)-0.65*rfRidge(frontLine-1.107,0.011);' + #10 +
    '    compressionRidges+=0.80*rfRidge(frontLine-1.127,0.010)-0.45*rfRidge(frontLine-1.150,0.014);' + #10 +
    '    compressedFold=0.0033*belly*(0.35+0.65*smoothstep(0.02,0.12,ax))*compressionRidges;' + #10 +
    // Centimetre-scale tension lines survive once the submillimetre weave fades.
    // Their envelopes follow the side seams and lower back, leaving the taut
    // scapular panels broad. Rest coordinates prevent crawling during skinning.
    '    float flank=rfBell((ax-0.139)/0.042)*rfBell((p.y-1.23)/0.12)*(1.0-smoothstep(0.015,0.065,p.z));' + #10 +
    '    float lower=rfBell((p.y-1.09)/0.064)*(1.0-smoothstep(0.13,0.18,ax))*back;' + #10 +
    // Finite diagonal folds, not repeated horizontal bands over the pockets.
    // Upper cloth follows trunk flexion, not the left/right crank phase.
    '    float diagonal=p.y+ax*0.45+0.12*p.z+0.006*sin(p.x*27.0);' + #10 +
    '    float drape=rfRidge(diagonal-1.258,0.0045)-0.42*rfRidge(diagonal-1.269,0.006);' + #10 +
    '    drape+=0.65*rfRidge(p.y+ax*0.68-1.351,0.006)-0.28*rfRidge(p.y+ax*0.68-1.366,0.009);' + #10 +
    '    fold+=0.0015*flank*drape;compressedFold+=0.0015*flank*drape;' + #10 +
    // Irregular gathers start at sewn pocket corners and die inside the
    // panel. Their slope, length and width differ; no waist-wide accordion.
    // The three pockets share a top edge; the outer panels sit on the back,
    // clear of the lateral silhouette (refine_rider_pockets.py).
    '    float pc=sign(p.x)*0.092*step(0.050,ax);' + #10 +
    '    float pocketWidth=mix(0.096,0.084,step(0.050,ax));' + #10 +
    '    float u=(p.x-pc)/pocketWidth+0.5;' + #10 +
    '    float pv=(p.y-1.026)/0.164;' + #10 +
    '    float panel=back*smoothstep(0.0,0.12,u)*(1.0-smoothstep(0.88,1.0,u))*smoothstep(0.0,0.10,pv)*(1.0-smoothstep(0.88,1.02,pv));' + #10 +
    '    float bias=pc/0.092,curve=0.10*pv*pv;' + #10 +
    '    float gline=u+(0.48+0.09*bias)*pv+curve-0.31-0.025*bias;' + #10 +
    '    float gathers=rfRidge(gline*pocketWidth,0.0045)*rfBell((pv-0.25-0.05*bias)/0.28);' + #10 +
    '    gathers+=(0.66-0.15*bias)*rfRidge((u-(0.32-0.05*bias)*pv-curve-0.67)*pocketWidth,0.0055)*rfBell((pv-0.35+0.04*bias)/0.25);' + #10 +
    '    gathers-=0.30*rfRidge((gline-0.10)*pocketWidth,0.006)*rfBell((pv-0.23)/0.24);' + #10 +
    '    fold+=0.00125*panel*gathers;' + #10 +
    '    fold+=0.0009*lower*rfBell((ax-0.09)/0.060)*(rfRidge(p.y+0.32*ax-1.077,0.005)-0.35*rfRidge(p.y+0.32*ax-1.088,0.008));' + #10 +
    // Cloth tension follows the actual left/right shoulder girdle, including
    // pose changes and standing effort. It is not another crank-driven sway.
    '    float reach=mix(rfReach.y,rfReach.x,smoothstep(-0.02,0.02,p.x));' + #10 +
    '    float scapular=rfBell((ax-0.108)/0.050)*rfBell((p.y-1.335)/0.078)*back;' + #10 +
    '    float pull=p.y+ax*0.40;' + #10 +
    '    fold+=0.0018*reach*scapular*(rfRidge(pull-1.382,0.011)-0.45*rfRidge(pull-1.407,0.016));' + #10 +
    '    float underarm=rfBell((ax-0.171)/0.041)*rfBell((p.y-1.312)/0.043);' + #10 +
    '    compressedFold+=0.0030*underarm*(rfRidge(p.y+0.35*ax-1.365,0.009)-0.5*rfRidge(p.y+0.35*ax-1.385,0.014));' + #10 +
    '  }else if(rfRegion<1.5){' + #10 +
    '    float axilla=(1.0-smoothstep(0.24,0.36,abs(p.x)))*(1.0-smoothstep(1.40,1.45,p.y));' + #10 +
    '    float sleeve=p.y+ax*0.45;' + #10 +
    '    compressedFold=0.0022*axilla*(rfRidge(sleeve-1.43,0.010)-0.45*rfRidge(sleeve-1.45,0.013));' + #10 +
    '  }else if(rfRegion<2.5){' + #10 +
    // Same rest-space wrap as rider_bibs_fit.py. This is the outer stitching
    // of a permanent garment insert, not a saddle/contact decal. Derivative
    // filtering keeps the seam's mean coverage after individual stitches fade.
    '    float s=0.102*atan(p.z+0.030,0.925-p.y);' + #10 +
    '    float width=0.060+0.045*rfBell((s+0.110)/0.065)+0.006*rfBell((s-0.100)/0.060);' + #10 +
    '    vec2 panel=vec2(p.x/width,s/0.181);' + #10 +
    '    float drop=max(0.0,0.840-p.y)/0.026;' + #10 +
    '    float edge=(sqrt(dot(panel,panel)+drop*drop)-1.0)*width;' + #10 +
    '    float perimeter=atan(panel.x,panel.y);' + #10 +
    '    float zigzag=0.0008*rfFold(perimeter*180.0);' + #10 +
    '    rfSeam=rfRidge(edge+0.001,0.0012);' + #10 +
    '    h+=0.00018*rfSeam+0.00018*rfRidge(edge+0.001-zigzag,0.00038);' + #10 +
    '    rfBibsPattern=rfFold(6.2831853*(rfUV.x+0.38*rfUV.y)/0.007)*(0.5+0.5*rfFold(6.2831853*rfUV.y/0.014));' + #10 +
    '    h+=0.000007*rfBibsPattern;' + #10 +
    '    float hip=smoothstep(0.81,0.87,p.y)*(1.0-smoothstep(0.98,1.025,p.y))*smoothstep(0.015,0.075,p.z);' + #10 +
    '    float hipLine=p.y+0.22*ax;' + #10 +
    '    compressedFold=0.00065*hip*(rfRidge(hipLine-0.898,0.012)-0.45*rfRidge(hipLine-0.931,0.017));' + #10 +
    // No painted crotch AO or rest-pose buttock crease. As the thigh rises,
    // those patches remain on the cloth and read as dirt. The deformed
    // surface supplies the large-scale volume; keep only weave and stitching.
    '  }' + #10 +
    '  h+=fold+rfProfile.y*0.65*rfMeso;' + #10 +
    '  vec3 dpdx=dFdx(v.xyz), dpdy=dFdy(v.xyz), N=normalize(n);' + #10 +
    // The yarn direction follows the deformed UV surface, including cached
    // GPU poses. No new tangent buffer or bone transform is required.
    '  if(rfRegion>1.5 && rfRegion<2.5){' + #10 +
    '    vec2 ux=dFdx(rfUV),uy=dFdy(rfUV);rfTangent=dpdx*uy.y-dpdy*ux.y;' + #10 +
    '  }' + #10 +
    '  vec3 r1=cross(dpdy,N), r2=cross(N,dpdx);' + #10 +
    '  float det=dot(dpdx,r1);' + #10 +
    // Strain is constant on each deformed triangle. Differentiating that
    // discontinuous amplitude creates false creases on the mesh diagonals.
    // Differentiate the smooth cloth relief, then apply the local strain.
    '  vec2 dh=vec2(dFdx(h),dFdy(h))+compression*vec2(dFdx(compressedFold),dFdy(compressedFold));' + #10 +
    '  vec3 grad=r1*dh.x+r2*dh.y;' + #10 +
    '  if(det*det>1e-12*dot(dpdx,dpdx)*dot(dpdy,dpdy)) {' + #10 +
    '    grad/=det; grad*=min(1.0,0.3/max(length(grad),1e-8));' + #10 +
    '    n=normalize(N-grad);' + #10 +
    '  }' + #10 +
    '}' + #10 +
    'void PLUG_main_texture_apply(inout vec4 c,const vec3 n) {' + #10 +
    '  c.rgb*=1.0+0.032*rfDetail+0.014*rfMeso+0.027*rfBibsPattern+0.065*rfSeam;' + #10 +
    '}' + #10 +
    'void PLUG_material_metallic_roughness(inout float m,inout float r) {' + #10 +
    '  m=0.0; r=clamp(rfProfile.z+0.025*rfDetail+0.022*rfMeso+0.020*rfBibsPattern+0.025*rfSeam,0.38,0.96);' + #10 +
    '  rfRoughness=r;' + #10 +
    '}' + #10 +
    // Charlie NDF (Estevez/Kulla 2017), Neubelt visibility; see Filament cloth model.
    // A modest fiber lobe suits cycling synthetics, rather than velvet.
    'void PLUG_physical_light_surface(inout vec3 diff,inout vec3 spec,const vec3 L,const vec3 N,const vec3 V) {' + #10 +
    '  if(rfRegion>4.5 || rz_complexity<2.5)return;' + #10 +
    '  float nl=max(dot(N,L),0.0),nv=max(dot(N,V),0.0);' + #10 +
    '  if(nl<=0.0 || nv<=0.0)return;' + #10 +
    '  vec3 H=L+V;H*=inversesqrt(max(dot(H,H),1e-8));float nh=clamp(dot(N,H),0.0,1.0);' + #10 +
    // Tight synthetic bibs reflect along the knit, rather than forming one
    // uniformly blurred highlight. Anisotropic GGX + correlated Smith masking
    // (equations documented in Filament, section Anisotropic specular BRDF).
    // Replace the isotropic lobe; adding another would brighten black fabric.
    '  if(rfRegion>1.5 && rfRegion<2.5){' + #10 +
    '    vec3 t=rfTangent-N*dot(rfTangent,N);float tt=dot(t,t);' + #10 +
    '    if(tt>1e-20){' + #10 +
    '      t*=inversesqrt(tt);vec3 b=cross(N,t);' + #10 +
    '      float alpha=rfRoughness*rfRoughness,at=alpha*1.35,ab=alpha*0.65;' + #10 +
    '      vec3 hLocal=vec3(dot(t,H)/at,dot(b,H)/ab,nh);float ellipse=dot(hLocal,hLocal);' + #10 +
    '      float ndf=1.0/max(3.14159265*at*ab*ellipse*ellipse,1e-6);' + #10 +
    '      float shadowV=nl*length(vec3(at*dot(t,V),ab*dot(b,V),nv));' + #10 +
    '      float shadowL=nv*length(vec3(at*dot(t,L),ab*dot(b,L),nl));' + #10 +
    '      float visibilityAniso=0.5/max(shadowV+shadowL,1e-5);' + #10 +
    '      float fresnel=0.04+0.96*pow(1.0-clamp(dot(V,H),0.0,1.0),5.0);' + #10 +
    '      spec=vec3(fresnel*ndf*visibilityAniso);' + #10 +
    '    }' + #10 +
    '  }' + #10 +
    '  float invAlpha=1.0/max(rfProfile.z*rfProfile.z,0.25);' + #10 +
    '  float D=(2.0+invAlpha)*pow(max(1.0-nh*nh,1e-5),0.5*invAlpha)/6.2831853;' + #10 +
    '  float visibility=1.0/max(4.0*(nl+nv-nl*nv),1e-4);' + #10 +
    // Fibre reflection inherits the dyed cloth colour. A neutral additive
    // lobe turned dark fabric chalky; the base and fibre lobes share energy.
    '  float strength=mix(0.055,0.12,smoothstep(0.70,0.90,rfProfile.z));' + #10 +
    '  vec3 fibre=sqrt(clamp(diff*3.14159265,vec3(0.0),vec3(1.0)));' + #10 +
    '  diff*=1.0-strength;spec=spec*(1.0-strength)+fibre*(strength*D*visibility);' + #10 +
    '}';
procedure TRiderFabric.Visit(Node: TX3DNode);
var Sh:TShapeNode; App:TAppearanceNode; Mat:TPhysicalMaterialNode;
  Geo:TAbstractComposedGeometryNode; Coord:TCoordinateNode;
  Attr,UVAttr,Metric:TFloatVertexAttributeNode; Eff:TEffectNode; V,F:TEffectPartNode;
  Profile:TVector4; P,Q:TVector3; Nm:String; I,J,A,B:Integer;
  UVNode:TX3DNode;UV:TTextureCoordinateNode;D:TVector2;
  SumWorld,SumUV:Double;UVScale,Region:Single;Morph:TFloatVertexAttributeNode;Breath:TSFFloat;Reach:TSFVec2f;
begin
  Sh:=TShapeNode(Node);
  if not(Sh.Appearance is TAppearanceNode)or
     not(Sh.Appearance.Material is TPhysicalMaterialNode)or
     not(Sh.Geometry is TAbstractComposedGeometryNode)then Exit;
  App:=TAppearanceNode(Sh.Appearance);Mat:=TPhysicalMaterialNode(App.Material);
  Nm:=LowerCase(App.X3DName+' '+Mat.X3DName);
  { Trim and zipper teeth must follow the same chest field as the fabric.
    Their material can also be used on shoes, which receive zero deltas. }
  if(Pos('kitlogo',LowerCase(Sh.X3DName))=1)or
    ((Pos('binding -',Nm)>0)and(Pos('part_jerseybinding',Nm)=0))or
    (Pos('zipper hardware',Nm)>0)then begin
    Geo:=TAbstractComposedGeometryNode(Sh.Geometry);
    if not(Geo.Coord is TCoordinateNode)then Exit;
    Coord:=TCoordinateNode(Geo.Coord);Morph:=AddRiderSurfaceAttribute(Geo);
    if Morph.FdValue.Count=0 then for I:=0 to Coord.FdPoint.Count-1 do
      AddRiderSurfaceDelta(Morph,RiderChestExpansion(Coord.FdPoint.Items[I]*FScale)*(1/FScale));
    for I:=0 to App.FdEffects.Count-1 do
      if App.FdEffects[I].X3DName='RiderGarmentDetailBreathing'then Exit;
    Eff:=TEffectNode.Create('RiderGarmentDetailBreathing');Eff.Language:=slGLSL;Eff.UniformMissing:=umIgnore;
    Breath:=TSFFloat.Create(Eff,True,'riderSurfaceAmount',0);Eff.AddCustomField(Breath);
    SetLength(FBreathFields,Length(FBreathFields)+1);FBreathFields[High(FBreathFields)]:=Breath;
    V:=TEffectPartNode.Create;V.ShaderType:=stVertex;V.Contents:=RiderSurfaceMotionVS;
    Eff.SetParts([V]);ShareRiderEffect(Eff);App.FdEffects.Add(Eff);
    Exit;
  end;
  { The broad reflection remains visible after yarn detail is filtered out.
    Tight synthetic panels, brushed compression fabric and open mesh have
    distinct roughness; increasing the weave amplitude cannot replace this. }
  if Pos('part_jersey',Nm)>0 then Profile:=Vector4(0.0011,0.000028,0.67,0)
  else if Pos('part_sleeves',Nm)>0 then Profile:=Vector4(0.0018,0.000035,0.58,2)
  else if Pos('part_shorts',Nm)>0 then Profile:=Vector4(0.00055,0.000014,0.56,2)
  else if Pos('part_socks',Nm)>0 then Profile:=Vector4(0.0014,0.000040,0.88,2)
  else if Pos('part_gloves',Nm)>0 then Profile:=Vector4(0.0010,0.000025,0.86,3)
  else Exit;
  if Pos('jerseyside',Nm)>0 then Profile:=Vector4(0.0015,0.000040,0.88,1);
  if Pos('jerseybinding',Nm)>0 then Profile:=Vector4(0.0011,0.000020,0.84,0);
  if Pos('shortssatin',Nm)>0 then Profile:=Vector4(0.00055,0.000012,0.50,2);
  if Pos('glovespalm',Nm)>0 then Profile:=Vector4(0.0010,0.000025,0.94,3);
  Region:=0;
  if Pos('part_sleeves',Nm)>0 then Region:=1;
  if Pos('part_shorts',Nm)>0 then Region:=2;
  if Pos('part_socks',Nm)>0 then Region:=3;
  if Pos('part_gloves',Nm)>0 then Region:=4;
  Geo:=TAbstractComposedGeometryNode(Sh.Geometry);
  if not(Geo.Coord is TCoordinateNode)then Exit;
  Coord:=TCoordinateNode(Geo.Coord);
  { An independent immutable attribute survives CGE's deformation buffer cache.
    Reading castle_Vertex here would make the weave swim on cached poses. }
  Attr:=nil;
  for I:=0 to Geo.FdAttrib.Count-1 do
    if (Geo.FdAttrib[I] is TFloatVertexAttributeNode)and
       (TFloatVertexAttributeNode(Geo.FdAttrib[I]).NameField='riderFabricRest')then
      Attr:=TFloatVertexAttributeNode(Geo.FdAttrib[I]);
  if Attr=nil then begin
    Attr:=TFloatVertexAttributeNode.Create;
    Attr.NameField:='riderFabricRest';Attr.NumComponents:=3;
    for I:=0 to Coord.FdPoint.Count-1 do begin
      P:=Coord.FdPoint.Items[I]*FScale;
      Attr.FdValue.Items.Add(P.X);Attr.FdValue.Items.Add(P.Y);Attr.FdValue.Items.Add(P.Z);
    end;
    Geo.FdAttrib.Add(Attr);
  end;
  UVNode:=Geo.TexCoord;
  if(UVNode is TMultiTextureCoordinateNode)and(TMultiTextureCoordinateNode(UVNode).FdTexCoord.Count>0)then
    UVNode:=TMultiTextureCoordinateNode(UVNode).FdTexCoord[0];
  UV:=nil;if UVNode is TTextureCoordinateNode then UV:=TTextureCoordinateNode(UVNode);
  if(UV<>nil)and(UV.FdPoint.Count<>Coord.FdPoint.Count)then UV:=nil;
  UVScale:=1;
  if(UV<>nil)and(Geo is TIndexedTriangleSetNode)then begin
    SumWorld:=0;SumUV:=0;
    for I:=0 to TIndexedTriangleSetNode(Geo).FdIndex.Count div 3-1 do
      for J:=0 to 2 do begin
        A:=TIndexedTriangleSetNode(Geo).FdIndex.Items[I*3+J];
        B:=TIndexedTriangleSetNode(Geo).FdIndex.Items[I*3+(J+1)mod 3];
        P:=Coord.FdPoint.Items[A]-Coord.FdPoint.Items[B];D:=UV.FdPoint.Items[A]-UV.FdPoint.Items[B];
        SumWorld:=SumWorld+P.LengthSqr;SumUV:=SumUV+D.LengthSqr;
      end;
    if SumUV>1e-12 then UVScale:=Sqrt(SumWorld/SumUV)*FScale;
  end;
  UVAttr:=TFloatVertexAttributeNode.Create;UVAttr.NameField:='riderFabricUV';UVAttr.NumComponents:=2;
  for I:=0 to Coord.FdPoint.Count-1 do begin
    if UV<>nil then D:=UV.FdPoint.Items[I]*UVScale
    else begin Q:=Coord.FdPoint.Items[I]*FScale;D:=Vector2(Q.X,Q.Y) end;
    UVAttr.FdValue.Items.Add(D.X);UVAttr.FdValue.Items.Add(D.Y);
  end;
  Geo.FdAttrib.Add(UVAttr);
  { Unlike pattern coordinates, the strain reference is updated on body/bind
    edits. A heavier or shorter rider must not acquire permanent wrinkles just
    because their proportions differ from the authoring mannequin. }
  Metric:=TFloatVertexAttributeNode.Create;Metric.NameField:='riderFabricMetric';Metric.NumComponents:=3;
  for I:=0 to Coord.FdPoint.Count-1 do begin
    P:=Coord.FdPoint.Items[I];
    Metric.FdValue.Items.Add(P.X);Metric.FdValue.Items.Add(P.Y);Metric.FdValue.Items.Add(P.Z);
  end;
  Geo.FdAttrib.Add(Metric);
  Morph:=AddRiderSurfaceAttribute(Geo);
  if Morph.FdValue.Count=0 then for I:=0 to Coord.FdPoint.Count-1 do begin
    P:=Coord.FdPoint.Items[I]*FScale;Q:=TVector3.Zero;
    if Region<1.5 then Q:=RiderChestExpansion(P)*(1/FScale);
    AddRiderSurfaceDelta(Morph,Q);
  end;
  { Material effects are shared by several shapes; vertex attributes are not. }
  for I:=0 to App.FdEffects.Count-1 do
    if App.FdEffects[I].X3DName='RiderProceduralFabric' then Exit;
  { These authored maps contain only a repeated micro-weave (no body/folds).
    The filtered weave above replaces them; mesoscopic cloth relief is added
    separately instead of stacking two competing thread patterns. }
  Mat.NormalTexture:=nil;Mat.MetallicRoughnessTexture:=nil;
  Mat.Metallic:=0;Mat.Roughness:=Profile.Z;
  Eff:=TEffectNode.Create('RiderProceduralFabric');
  AttachRenderComplexity(Eff,rdRider);
  Eff.Language:=slGLSL;Eff.UniformMissing:=umIgnore;
  Breath:=TSFFloat.Create(Eff,True,'riderSurfaceAmount',0);Eff.AddCustomField(Breath);
  SetLength(FBreathFields,Length(FBreathFields)+1);FBreathFields[High(FBreathFields)]:=Breath;
  Eff.AddCustomField(TSFVec4f.Create(Eff,True,'rfProfile',Profile));
  Eff.AddCustomField(TSFFloat.Create(Eff,True,'rfRegion',Region));
  Reach:=TSFVec2f.Create(Eff,True,'rfReach',Vector2(0,0));Eff.AddCustomField(Reach);
  SetLength(FReachFields,Length(FReachFields)+1);FReachFields[High(FReachFields)]:=Reach;
  V:=TEffectPartNode.Create;V.ShaderType:=stVertex;V.Contents:=RiderSurfaceMotionVS+FabricVS;
  F:=TEffectPartNode.Create;F.ShaderType:=stFragment;F.Contents:=FabricFS;
  Eff.SetParts([V,F]);ShareRiderEffect(Eff);App.FdEffects.Add(Eff);
end;

constructor TRiderFabric.Create(Root:TX3DNode;Height:Single);
begin
  inherited Create;FScale:=1.8/Max(Height,0.5);
  if Root=nil then Exit;
  Root.EnumerateNodes(TShapeNode,@Visit,False);
end;
procedure TRiderFabric.Update(BreathPhase:Double;BreathLoad:Single;
  ShoulderLeft,ShoulderRight:Single);
var Reach:TVector2;I:Integer;Expansion:Single;
begin
  Expansion:=(0.5+0.5*Sin(BreathPhase*2*Pi))*(0.25+0.75*EnsureRange(BreathLoad/1.5,0,1));
  for I:=0 to High(FBreathFields)do FBreathFields[I].Send(Expansion);
  Reach:=Vector2(EnsureRange(ShoulderLeft/20,-1.0,1.0),EnsureRange(ShoulderRight/20,-1.0,1.0));
  if(Reach-FPreviousReach).LengthSqr>0.000004 then begin
    FPreviousReach:=Reach;
    for I:=0 to High(FReachFields)do FReachFields[I].Send(Reach);
  end;
end;
procedure ApplyRiderFabric(Root:TX3DNode);
var C:TRiderFabric;
begin
  C:=TRiderFabric.Create(Root,1.8);C.Free;
end;
end.
