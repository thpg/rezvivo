unit RiderSkinShader;
{$mode objfpc}{$H+}
interface
uses X3DNodes,X3DFields,CastleVectors;
type
  TRiderSkin=class
  private
    FScale,FHeadSurfaceOffset:Single;
    FTime:Double;
    FFields:array of TSFVec4f;
    FMouthFields:array of TSFFloat;
    FEyes,FEyeSkin,FIris:array[0..1]of TVector3;
    FMouth:TVector3;
    FFaceValid:Boolean;
    FGeometricFace,FGeometricEyes,FDetailActive:Boolean;
    procedure Visit(Node:TX3DNode);
    procedure VisitEye(Sh:TShapeNode);
    procedure VisitOral(Sh:TShapeNode);
    procedure SetTime(const Value:Double);
  public
    constructor Create(Root:TX3DNode;Height:Single;const FaceFile:String;GeometricFace:Boolean=False;GeometricEyes:Boolean=False);
    { Strain already includes facial visibility and manual expression overrides. }
    procedure Update(Dt,Strain:Single;BreathPhase:Double=0;BreathLoad:Single=0;Detail:Single=1);
    property Time:Double read FTime write SetTime;
  end;
{ Load-time installation; the shader uses bind coordinates, never a world hash. }
procedure ApplyRiderSkin(Root:TX3DNode;Height:Single);
implementation
uses SysUtils,Math,Classes,fpjson,jsonparser,CastleRenderOptions,CastleImages,RiderSurfaceMotion,RiderFace;
var SkinDiffusionTexture:TImageTextureNode;

function SkinDiffusionLut:TImageTextureNode;
const Width=128;Height=32;Samples=65;
  Diffusion:array[0..2]of Double=(0.0018,0.00075,0.00040);
var Img:TRGBAlphaFloatImage;Props:TTexturePropertiesNode;
  X,Y,C,K:Integer;NL,Curvature,T,Weight,Integral,Total,Theta:Double;Pixel:TVector4;
begin
  if SkinDiffusionTexture<>nil then Exit(SkinDiffusionTexture);
  { Integrate diffuse irradiance across a curved surface once. The three
    diffusion widths are an appearance approximation in metres. One linear
    data texture is shared by every avatar, with no screen-space pass. }
  Img:=TRGBAlphaFloatImage.Create(Width,Height);
  try
    for Y:=0 to Height-1 do for X:=0 to Width-1 do begin
      NL:=2*X/(Width-1)-1;Theta:=ArcCos(EnsureRange(NL,-1,1));
      Curvature:=200*Y/(Height-1);Pixel:=Vector4(0,0,0,1);
      for C:=0 to 2 do begin
        Integral:=0;Total:=0;
        for K:=0 to Samples-1 do begin
          T:=6*K/(Samples-1)-3;Weight:=Exp(-0.5*T*T);
          Integral:=Integral+Weight*Max(0,Cos(Theta+T*Diffusion[C]*Curvature));
          Total:=Total+Weight;
        end;
        Pixel.Data[C]:=Integral/Total;
      end;
      PVector4(Img.PixelPtr(X,Y))^:=Pixel;
    end;
    SkinDiffusionTexture:=TImageTextureNode.Create;
    SkinDiffusionTexture.KeepExistingBegin;
    Props:=TTexturePropertiesNode.Create;Props.GUITexture:=True;Props.GenerateMipMaps:=False;
    Props.FdMinificationFilter.Value:='AVG_PIXEL';Props.FdMagnificationFilter.Value:='AVG_PIXEL';
    SkinDiffusionTexture.FdTextureProperties.Value:=Props;
    SkinDiffusionTexture.RepeatS:=False;SkinDiffusionTexture.RepeatT:=False;
    SkinDiffusionTexture.LoadFromImage(Img,True,'');Img:=nil;
  finally Img.Free end;
  Result:=SkinDiffusionTexture;
end;
const
  OralVS=
    'attribute float riderEnamel;varying float roEnamel;'+#10+
    'void PLUG_vertex_eye_space(const vec4 v,const vec3 n){roEnamel=riderEnamel;}';
  OralFS=
    'varying float roEnamel;'+#10+
    'void PLUG_material_metallic_roughness(inout float m,inout float r){m=0.0;r=mix(0.78,0.40,roEnamel);}'+#10+
    // The lining is inside the lips, not an exposed skin surface. Ambient
    // occlusion also applies to the shared rider sky-light approximation.
    'void PLUG_material_occlusion(inout vec4 light){light.rgb*=mix(0.14,0.90,roEnamel);}';
  EyeVS=
    'attribute vec2 riderEyeUV;varying vec2 reUV;'+#10+
    'void PLUG_vertex_eye_space(const vec4 v,const vec3 n){reUV=riderEyeUV*2.0-1.0;}';
  EyeFS=
    'varying vec2 reUV;uniform vec3 reIris;float reR=0.0;'+#10+
    'void PLUG_main_texture_apply(inout vec4 c,const vec3 n){'+#10+
    ' vec2 p=reUV;float r=length(p);reR=r;float fw=max(fwidth(r),0.015);float a=atan(p.y,p.x);'+#10+
    ' float spokes=sin(a*47.0+4.0*sin(a*13.0)+r*9.0)*exp2(-3.0*pow(fwidth(a*47.0),2.0));'+#10+
    ' vec3 iris=reIris*(0.82+0.18*spokes);iris*=mix(1.0,0.32,smoothstep(0.80,1.0,r));'+#10+
    ' iris=mix(vec3(0.0025,0.003,0.004),iris,smoothstep(0.31-fw,0.31+fw,r));'+#10+
    ' vec3 white=vec3(0.48,0.46,0.43);white=mix(white,vec3(0.42,0.28,0.26),0.22*smoothstep(1.5,2.3,abs(p.x)));'+#10+
    ' c.rgb=mix(iris,white,smoothstep(1.0-fw,1.0+fw,r));'+#10+
    ' c.rgb*=1.0-0.34*smoothstep(0.0,0.8,p.y); }'+#10+
    'void PLUG_material_metallic_roughness(inout float m,inout float r){m=0.0;r=mix(0.10,0.24,smoothstep(0.95,1.12,reR));}';
  SkinVS=
    'attribute vec4 riderSkinRest;varying vec3 rsPosition;varying float rsCavity;'+#10+
    'void PLUG_vertex_eye_space(const vec4 v,const vec3 n){rsPosition=riderSkinRest.xyz;rsCavity=riderSkinRest.w;}';
  SkinFS=
    'varying vec3 rsPosition;varying float rsCavity;uniform float rsPortrait,rsFaceValid,rsGeometricEyes,rsCleanPortrait;uniform vec4 rsFace;'+#10+
    'uniform sampler2D rsDiffusion;vec3 rsSmoothNormal=vec3(0.0,1.0,0.0);float rsCurvature=0.0;'+#10+
    'uniform vec3 rsEyeL,rsEyeR,rsSkinL,rsSkinR,rsIrisL,rsIrisR,rsMouth;uniform float riderSurfaceAmount,rsHeadSurfaceOffset;'+#10+
    'vec3 rsAlbedo=vec3(0.4);float rsPores=0.0,rsOil=0.0,rsThin=0.0,rsEye=0.0,rsCrease=0.0,rsLip=0.0,rsBodyTone=0.0,rsJointTone=0.0,rsInnerTone=0.0;'+#10+
    'vec3 rsEyeOffset(){return rsPosition-(rsPosition.x<0.0?rsEyeL:rsEyeR);}'+#10+
    'float rsEyeArea(vec3 q){vec2 radius=mix(vec2(0.014,0.0070),vec2(0.018,0.010),rsFace.x);float e=length(q.xy/radius);return (1.0-smoothstep(mix(0.90,0.55,rsFace.x),1.04,e))*(1.0-smoothstep(0.008,0.016,abs(q.z)))*rsFaceValid*rsPortrait;}'+#10+
    'float rsBand(float x,float a,float b,float c,float d){return smoothstep(a,b,x)*(1.0-smoothstep(c,d,x));}'+#10+
    'float rsFurrow(float d,float width){float w=max(width,fwidth(d));return exp(-pow(d/w,2.0))*width/w;}'+#10+
    'vec2 rsLidMargins(vec3 q){float arc=sqrt(max(1.0-pow(q.x/0.0129,2.0),0.0));float tilt=0.0005*q.x/0.0129*sign(rsPosition.x);return vec2(0.0046*arc,-0.0038*arc)+tilt;}'+#10+
    'float rsTension(vec3 p){'+#10+
    ' vec3 mid=(rsEyeL+rsEyeR)*0.5;vec3 b=p-mid;vec3 m=p-rsMouth;'+#10+
    ' float front=smoothstep(0.025,0.055,p.z);'+#10+
    ' float brow=rsFurrow(abs(b.x)-(0.004+0.14*max(b.y-0.010,0.0)),0.0011)*rsBand(b.y,0.004,0.010,0.024,0.034);'+#10+
    ' float cheek=rsFurrow(abs(m.x)-(0.014+0.016*sqrt(clamp((0.028-m.y)/0.050,0.0,1.0))),0.0013)*rsBand(m.y,-0.014,-0.004,0.025,0.039);'+#10+
    ' return (brow+0.50*cheek)*front*rsFaceValid*rsPortrait*rsFace.w; }'+#10+
    'float rsMicro(vec2 p){'+#10+
    ' vec2 q=p/0.00065;vec2 f=exp2(-6.0*fwidth(q)*fwidth(q));'+#10+
    ' return (sin(q.x*6.283185+sin(q.y*3.1))*sin(q.y*5.7+sin(q.x*2.3)))*f.x*f.y; }'+#10+
    'void PLUG_fragment_eye_space(const vec4 v,inout vec3 n){'+#10+
    // Retain compatibility with older imported portraits. The anatomical
    // head has consistently wound, single-sided eyelid and lip loops.
    '#ifndef CASTLE_BUGGY_FRONT_FACING'+#10+
    ' if(rsPortrait>0.5 && rsCleanPortrait<0.5){if(gl_FrontFacing){}else n=-n;}'+#10+
    '#endif'+#10+
    ' rsSmoothNormal=normalize(n);'+#10+
    // Estimate curvature before pore/facial detail so micro normals cannot
    // make the skin glow. Clamp the small, noisy end of the pixel footprint.
    ' float dP=max(dot(dFdx(v.xyz),dFdx(v.xyz))+dot(dFdy(v.xyz),dFdy(v.xyz)),1e-10);'+#10+
    ' float dN=dot(dFdx(rsSmoothNormal),dFdx(rsSmoothNormal))+dot(dFdy(rsSmoothNormal),dFdy(rsSmoothNormal));'+#10+
    ' rsCurvature=clamp(sqrt(dN/dP),0.0,200.0);'+#10+
    ' vec3 p=rsPosition;vec3 w=abs(cross(dFdx(p),dFdy(p)));w/=max(w.x+w.y+w.z,1e-12);'+#10+
    ' rsPores=dot(w,vec3(rsMicro(p.yz),rsMicro(p.xz),rsMicro(p.xy)));'+#10+
    // Broad, low-contrast variation in bind space survives the pore LOD.
    // Multipliers preserve chosen skin colour, including darker skin tones.
    ' float body=1.0-rsPortrait;'+#10+
    ' rsBodyTone=body*(0.60*rsBand(p.y,0.30,0.37,0.49,0.56)*smoothstep(-0.04,0.035,p.z)+0.40*rsBand(abs(p.x),0.35,0.40,0.52,0.59));'+#10+
    ' float knee=rsBand(p.y,0.40,0.46,0.55,0.61)*smoothstep(-0.01,0.05,p.z);'+#10+
    ' float elbow=rsBand(abs(p.x),0.36,0.40,0.46,0.50)*rsBand(p.y,1.26,1.32,1.43,1.49);'+#10+
    ' rsJointTone=body*max(knee,elbow);'+#10+
    // Broad exposure differences survive the pore LOD without painting veins
    // or a repeating noise pattern onto every limb.
    ' float arm=rsBand(abs(p.x),0.27,0.36,0.59,0.65);'+#10+
    ' float armAxis=1.43-(abs(p.x)-0.22)*0.105;'+#10+
    ' rsInnerTone=body*arm*(1.0-smoothstep(armAxis-0.022,armAxis+0.016,p.y));'+#10+
    ' vec3 h=p-vec3(0.0,1.612+rsHeadSurfaceOffset,-0.040);float front=smoothstep(0.025,0.060,h.z);'+#10+
    ' rsOil=rsPortrait*front*(1.0-smoothstep(0.016,0.040,abs(h.x)))*rsBand(h.y,-0.025,0.0,0.09,0.12);'+#10+
    ' rsThin=rsPortrait*smoothstep(0.063,0.082,abs(h.x))*rsBand(h.y,-0.025,-0.005,0.050,0.075);'+#10+
    ' vec3 lip=p-rsMouth;float lipY=lip.y-0.0012*pow(lip.x/0.030,2.0);'+#10+
    ' rsLip=(1.0-smoothstep(0.75,1.1,length(vec2(lip.x/0.029,lipY/0.007))))*smoothstep(0.04,0.075,p.z)*rsPortrait*rsFaceValid;'+#10+
    ' float area=0.0,cornea=0.0;'+#10+
    ' if(rsPortrait>0.5 && rsFaceValid>0.5 && rsFace.w>0.0)rsCrease=rsTension(p);'+#10+
    ' if(rsPortrait>0.5 && rsFaceValid>0.5 && rsGeometricEyes<0.5){'+#10+
    ' vec3 eye=rsEyeOffset();area=rsEyeArea(eye);'+#10+
    ' float curve=clamp(pow(eye.x/0.014,2.0),0.0,1.0);float edge=max(fwidth(eye.y),0.00045);'+#10+
    ' float openY=(0.0065-rsFace.w*(0.0040+0.0020*curve))*(1.0-rsFace.x);'+#10+
    ' float lid=smoothstep(openY-edge,openY+edge,eye.y+rsFace.x*0.0074);'+#10+
    ' float lowY=-0.0060+rsFace.w*(0.0030+0.0020*curve);'+#10+
    ' float lower=mix(1.0,smoothstep(lowY-edge,lowY+edge,eye.y),rsFace.w);'+#10+
    ' rsEye=area*(1.0-lid)*lower;'+#10+
    ' cornea=max(1.0-dot(eye.xy/vec2(0.012,0.006),eye.xy/vec2(0.012,0.006)),0.0); }'+#10+
    ' float fold=0.0;if(rsGeometricEyes>0.5 && rsPortrait>0.5 && rsCleanPortrait<0.5){vec3 q=rsEyeOffset();vec2 margin=rsLidMargins(q);fold=rsFurrow(q.y-margin.x-0.0035,0.0007)*(1.0-smoothstep(0.010,0.017,abs(q.x)))*(1.0-smoothstep(0.016,0.025,abs(q.z)));}'+#10+
    ' float height=rsPores*0.000020*(1.0-area)*(1.0-0.7*rsLip)+rsEye*cornea*0.00020-rsCrease*0.00016-fold*0.00025;vec3 N=normalize(n),dx=dFdx(v.xyz),dy=dFdy(v.xyz);'+#10+
    ' vec3 a=cross(dy,N),b=cross(N,dx);float det=dot(dx,a);'+#10+
    ' if(det*det>1e-12*dot(dx,dx)*dot(dy,dy)){vec3 g=(a*dFdx(height)+b*dFdy(height))/det;n=normalize(N-g*min(1.0,mix(0.12,0.35,rsFace.w)/max(length(g),1e-6)));}'+#10+
    '}'+#10+
    'void PLUG_main_texture_apply(inout vec4 c,const vec3 n){'+#10+
    ' c.rgb*=vec3(1.0)+vec3(0.045,0.028,0.014)*rsBodyTone+vec3(0.070,-0.026,-0.038)*rsJointTone+vec3(0.038,0.032,0.024)*rsInnerTone;'+#10+
    ' if(rsCleanPortrait>0.5){'+#10+
    ' vec3 p=rsPosition;vec3 skin=(rsSkinL+rsSkinR)*0.5;'+#10+
    // The CC0 scan contains shaved scalp stubble. The base scalp is bald;
    // visible hair belongs exclusively to the selected groom.
    ' float scalpY=p.y-rsHeadSurfaceOffset;'+#10+
    ' float scalp=max(smoothstep(1.714,1.755,scalpY),(1.0-smoothstep(-0.035,0.020,p.z))*smoothstep(1.58,1.68,scalpY));'+#10+
    ' scalp=max(scalp,smoothstep(0.047,0.069,abs(p.x))*smoothstep(1.678,1.722,scalpY));'+#10+
    ' c.rgb=mix(c.rgb,skin*(0.99+0.01*rsPores),scalp);'+#10+
    // Fine brow strands use rest-space coordinates, so they follow the same
    // deformed loops as the brow surface, without another draw or atlas.
    ' float t=(abs(p.x)-0.010)/0.048;float eyeY=(rsEyeL.y+rsEyeR.y)*0.5;'+#10+
    ' float line=eyeY+0.021+0.004*sin(clamp(t,0.0,1.0)*3.141593)-0.003*t;'+#10+
    ' float thick=mix(0.0024,0.0006,clamp(t,0.0,1.0));float fw=max(fwidth(p.y),0.00022);'+#10+
    ' float brow=(1.0-smoothstep(thick-fw,thick+fw,abs(p.y-line)))*rsBand(t,-0.07,0.12,0.86,1.06)*smoothstep(0.035,0.060,p.z);'+#10+
    ' float strand=sin((abs(p.x)+(p.y-line)*0.75)*6800.0);float detail=exp2(-4.0*pow(fwidth(p.x*6800.0),2.0));'+#10+
    ' c.rgb=mix(c.rgb,vec3(0.065,0.038,0.024)*(0.90+0.20*strand*detail),brow*0.77); }'+#10+
    ' if(rsPortrait>0.5 && rsFaceValid>0.5 && rsGeometricEyes>0.5 && rsCleanPortrait<0.5){'+#10+
    ' vec3 q=rsEyeOffset();float lid=(1.0-smoothstep(0.94,1.22,length(q.xy/vec2(0.019,0.014))))*(1.0-smoothstep(0.016,0.025,abs(q.z)));'+#10+
    ' vec3 skin=rsPosition.x<0.0?rsSkinL:rsSkinR;skin*=0.97+0.03*rsPores;'+#10+
    ' c.rgb=mix(c.rgb,skin,lid);vec2 margin=rsLidMargins(q);float span=1.0-smoothstep(0.0122,0.0134,abs(q.x));'+#10+
    ' float lash=rsFurrow(q.y-margin.x,0.00025)*span*lid;float wet=rsFurrow(q.y-margin.y,0.00032)*span*lid;'+#10+
    ' c.rgb=mix(c.rgb,vec3(0.030,0.016,0.011),lash*0.72);c.rgb=mix(c.rgb,skin*vec3(0.87,0.64,0.62),wet*0.65); }'+#10+
    ' if(rsPortrait>0.5 && rsFaceValid>0.5 && rsGeometricEyes<0.5){'+#10+
    ' vec3 q=rsEyeOffset();float area=rsEyeArea(q);'+#10+
    ' vec2 gaze=rsFace.yz;float r=length(q.xy-gaze)/0.0055;float fw=max(fwidth(r),0.03);'+#10+
    ' vec3 iris=rsPosition.x<0.0?rsIrisL:rsIrisR;float a=atan(q.y-gaze.y,q.x-gaze.x);'+#10+
    ' iris*=0.72+0.18*sin(a*37.0+r*13.0)*exp2(-4.0*fwidth(a*37.0)*fwidth(a*37.0));'+#10+
    ' iris=mix(iris*0.20,iris,1.0-smoothstep(0.85,1.0,r));'+#10+
    ' iris=mix(vec3(0.004),iris,smoothstep(0.35-fw,0.35+fw,r));'+#10+
    ' vec3 eye=mix(iris,vec3(0.37,0.35,0.33),smoothstep(1.0-fw,1.0+fw,r));'+#10+
    ' eye*=1.0-0.32*smoothstep(0.0,0.005,q.y);'+#10+
    ' eye=mix(c.rgb,eye,0.22*(1.0-smoothstep(0.75,1.05,r)));'+#10+
    ' vec3 skin=rsPosition.x<0.0?rsSkinL:rsSkinR;'+#10+
    ' float crease=exp(-pow((q.y+0.0030-0.003*pow(q.x/0.018,2.0))/0.00038,2.0));skin*=1.0-0.24*crease*rsFace.x;'+#10+
    ' float curve=clamp(pow(q.x/0.014,2.0),0.0,1.0);'+#10+
    ' float tensionLid=rsFurrow(q.y-(0.0065-rsFace.w*(0.0040+0.0020*curve))-0.0008,0.0018);'+#10+
    ' skin*=1.0-(0.16+0.14*tensionLid)*rsFace.w*(1.0-rsFace.x);'+#10+
    ' float openFraction=area>0.001?rsEye/area:0.0;'+#10+
    ' c.rgb=mix(c.rgb,mix(skin,eye,openFraction),area);'+#10+
    ' vec3 m=rsPosition-rsMouth;float mw=max(1.0-pow(m.x/0.030,2.0),0.0);'+#10+
    ' float gap=(0.0002+0.0026*riderSurfaceAmount)*mw;float edge=max(fwidth(m.y),0.00015);'+#10+
    ' float cavity=(1.0-smoothstep(gap-edge,gap+edge,abs(m.y+0.0005)))*smoothstep(0.035,0.065,rsPosition.z)*mw*rsFaceValid*rsPortrait;'+#10+
    ' cavity*=smoothstep(0.08,0.30,riderSurfaceAmount);c.rgb=mix(c.rgb,vec3(0.018,0.006,0.006),cavity); }rsAlbedo=c.rgb;'+#10+
    '}'+#10+
    // Broad body highlights must not turn the whole forearm/knee into a
    // polished strip. Retain the spatial variation and skin reflection;
    // portrait oil, lip and eye responses keep their own existing values.
    'void PLUG_material_metallic_roughness(inout float m,inout float r){m=0.0;r=mix(mix(clamp(mix(0.54,mix(0.55,0.62,rsCleanPortrait),rsPortrait)-mix(0.16,0.09,rsCleanPortrait)*rsOil+0.035*rsPores+0.055*rsBodyTone-0.015*rsJointTone+0.040*rsInnerTone,0.35,mix(0.74,0.70,rsPortrait)),mix(0.33,0.40,rsCleanPortrait),rsLip),0.22,rsEye);}'+#10+
    'void PLUG_physical_light_surface(inout vec3 diff,inout vec3 spec,const vec3 L,const vec3 N,const vec3 V){spec*=0.72;}'+#10+
    'void PLUG_material_occlusion(inout vec4 light){light.rgb*=mix(1.0,0.10,rsCavity);}'+#10+
    'void PLUG_physical_light_contribution(inout vec3 light,const vec3 L,const vec3 N,const vec3 V){'+#10+
    ' float nl=dot(rsSmoothNormal,L);vec2 uv=vec2(nl*0.5+0.5,rsCurvature/200.0);'+#10+
    ' uv=uv*vec2(127.0/128.0,31.0/32.0)+vec2(0.5/128.0,0.5/32.0);'+#10+
    ' vec3 integrated=texture2D(rsDiffusion,uv).rgb;'+#10+
    // Replace part of the Lambert lobe; do not add an unrelated red glow.
    // Shadow attenuation is still applied by the enclosing light code.
    ' light+=rsAlbedo*(1.0-rsEye)*(1.0-rsCavity)*0.80*(integrated-vec3(max(nl,0.0)))/3.14159265;'+#10+
    ' light+=rsAlbedo*vec3(1.0,0.38,0.21)*(rsThin*0.12*pow(max(-nl,0.0),2.0))/3.14159265;'+#10+
    '}';
procedure TRiderSkin.VisitEye(Sh:TShapeNode);
var Geo:TAbstractComposedGeometryNode;UV:TX3DNode;Tex:TTextureCoordinateNode;
  Attr:TFloatVertexAttributeNode;App:TAppearanceNode;Eff:TEffectNode;V,F:TEffectPartNode;I:Integer;
begin
  if not(Sh.Geometry is TAbstractComposedGeometryNode)then Exit;
  App:=TAppearanceNode(Sh.Appearance);
  for I:=0 to App.FdEffects.Count-1 do if App.FdEffects[I].X3DName='RiderEyeSurface'then Exit;
  Geo:=TAbstractComposedGeometryNode(Sh.Geometry);UV:=Geo.TexCoord;
  if(UV is TMultiTextureCoordinateNode)and(TMultiTextureCoordinateNode(UV).FdTexCoord.Count>0)then UV:=TMultiTextureCoordinateNode(UV).FdTexCoord[0];
  if not(UV is TTextureCoordinateNode)then Exit;Tex:=TTextureCoordinateNode(UV);
  Attr:=TFloatVertexAttributeNode.Create;Attr.NameField:='riderEyeUV';Attr.NumComponents:=2;
  for I:=0 to Tex.FdPoint.Count-1 do begin Attr.FdValue.Items.Add(Tex.FdPoint.Items[I].X);Attr.FdValue.Items.Add(Tex.FdPoint.Items[I].Y) end;
  Geo.FdAttrib.Add(Attr);App:=TAppearanceNode(Sh.Appearance);
  Eff:=TEffectNode.Create('RiderEyeSurface');Eff.Language:=slGLSL;Eff.UniformMissing:=umIgnore;
  Eff.AddCustomField(TSFVec3f.Create(Eff,True,'reIris',(FIris[0]+FIris[1])*0.5));
  V:=TEffectPartNode.Create;V.ShaderType:=stVertex;V.Contents:=EyeVS;
  F:=TEffectPartNode.Create;F.ShaderType:=stFragment;F.Contents:=EyeFS;
  Eff.SetParts([V,F]);App.FdEffects.Add(Eff);
end;
procedure TRiderSkin.VisitOral(Sh:TShapeNode);
var Geo:TAbstractComposedGeometryNode;Colors:TColorRGBANode;Coord:TCoordinateNode;
  Attr:TFloatVertexAttributeNode;App:TAppearanceNode;Eff:TEffectNode;V,F:TEffectPartNode;
  I:Integer;C:TVector4;
begin
  App:=TAppearanceNode(Sh.Appearance);
  for I:=0 to App.FdEffects.Count-1 do if App.FdEffects[I].X3DName='RiderOralSurface'then Exit;
  Geo:=TAbstractComposedGeometryNode(Sh.Geometry);
  if not(Geo.FdColor.Value is TColorRGBANode)or not(Geo.Coord is TCoordinateNode)then Exit;
  Colors:=TColorRGBANode(Geo.FdColor.Value);Coord:=TCoordinateNode(Geo.Coord);
  if Colors.FdColor.Count<>Coord.FdPoint.Count then Exit;
  Attr:=TFloatVertexAttributeNode.Create;Attr.NameField:='riderEnamel';Attr.NumComponents:=1;
  // Crowns and lining already have separate vertices in the one oral mesh.
  // Classify their authored vertex colours once, without another draw call.
  for I:=0 to Colors.FdColor.Count-1 do begin
    C:=Colors.FdColor.Items[I];
    Attr.FdValue.Items.Add(Ord((C.Y>0.70*C.X)and(C.Z>0.55*C.X)));
  end;
  Geo.FdAttrib.Add(Attr);
  Eff:=TEffectNode.Create('RiderOralSurface');Eff.Language:=slGLSL;Eff.UniformMissing:=umIgnore;
  V:=TEffectPartNode.Create;V.ShaderType:=stVertex;V.Contents:=OralVS;
  F:=TEffectPartNode.Create;F.ShaderType:=stFragment;F.Contents:=OralFS;
  Eff.SetParts([V,F]);App.FdEffects.Add(Eff);
end;
procedure TRiderSkin.Visit(Node:TX3DNode);
var Sh:TShapeNode;App:TAppearanceNode;Mat:TPhysicalMaterialNode;
  Geo:TAbstractComposedGeometryNode;Coord:TCoordinateNode;Attr:TFloatVertexAttributeNode;
  Eff:TEffectNode;V,F:TEffectPartNode;Nm:String;P,Delta:TVector3;I:Integer;Portrait:Boolean;FaceField:TSFVec4f;
  Morph:TFloatVertexAttributeNode;MouthField:TSFFloat;Weight:Single;
  DiffusionField:TSFNode;SkinUV:TX3DNode;SkinTex:TTextureCoordinateNode;Cavity:Single;TexP:TVector2;
begin
  Sh:=TShapeNode(Node);
  if not(Sh.Appearance is TAppearanceNode)or not(Sh.Appearance.Material is TPhysicalMaterialNode)
    or not(Sh.Geometry is TAbstractComposedGeometryNode)then Exit;
  App:=TAppearanceNode(Sh.Appearance);Mat:=TPhysicalMaterialNode(App.Material);
  Nm:=LowerCase(App.X3DName+' '+Mat.X3DName);
  if(Pos('mouth',Nm)>0)and(Pos('enamel',Nm)>0)then begin VisitOral(Sh);Exit end;
  if(Pos('eye_surface',Nm)>0)or(Pos('eye surface',Nm)>0)then begin VisitEye(Sh);Exit end;
  Portrait:=Pos('portrait',Nm)>0;
  if not Portrait and(Pos('skin -',Nm)=0)and(Pos('part_skin',Nm)=0)then Exit;
  Geo:=TAbstractComposedGeometryNode(Sh.Geometry);if not(Geo.Coord is TCoordinateNode)then Exit;
  Coord:=TCoordinateNode(Geo.Coord);Attr:=nil;
  for I:=0 to Geo.FdAttrib.Count-1 do
    if(Geo.FdAttrib[I]is TFloatVertexAttributeNode)and
      (TFloatVertexAttributeNode(Geo.FdAttrib[I]).NameField='riderSkinRest')then Attr:=TFloatVertexAttributeNode(Geo.FdAttrib[I]);
  if Attr=nil then begin
    Attr:=TFloatVertexAttributeNode.Create;Attr.NameField:='riderSkinRest';Attr.NumComponents:=4;
    SkinUV:=Geo.TexCoord;SkinTex:=nil;
    if(SkinUV is TMultiTextureCoordinateNode)and(TMultiTextureCoordinateNode(SkinUV).FdTexCoord.Count>0)then
      SkinUV:=TMultiTextureCoordinateNode(SkinUV).FdTexCoord[0];
    if SkinUV is TTextureCoordinateNode then SkinTex:=TTextureCoordinateNode(SkinUV);
    for I:=0 to Coord.FdPoint.Count-1 do begin
      P:=Coord.FdPoint.Items[I]*FScale;
      Attr.FdValue.Items.Add(P.X);Attr.FdValue.Items.Add(P.Y);Attr.FdValue.Items.Add(P.Z);
      Cavity:=0;
      if(Pos('anatomicalportrait',Nm)>0)and(SkinTex<>nil)and(I<SkinTex.FdPoint.Count)then begin
        TexP:=SkinTex.FdPoint.Items[I];
        if(TexP.X>0.75)and(TexP.X<0.93)and((TexP.Y<0.14)or(TexP.Y>0.86))then Cavity:=1;
      end;
      Attr.FdValue.Items.Add(Cavity);
    end;
    Geo.FdAttrib.Add(Attr);
  end;
  Mat.Metallic:=0;Mat.Roughness:=0.58;Mat.MetallicRoughnessTexture:=nil;
  Morph:=AddRiderSurfaceAttribute(Geo);
  if Morph.FdValue.Count=0 then for I:=0 to Coord.FdPoint.Count-1 do begin
    P:=Coord.FdPoint.Items[I]*FScale;Delta:=TVector3.Zero;
    if Portrait and FFaceValid and not FGeometricFace then begin
      Weight:=(1-EnsureRange((P.Y-FMouth.Y+0.004)/0.007,0,1))*
        EnsureRange((P.Y-FMouth.Y+0.09)/0.05,0,1)*
        (1-EnsureRange((Abs(P.X)-0.035)/0.035,0,1))*EnsureRange((P.Z-0.015)/0.040,0,1);
      Delta:=Vector3(0,-0.0048,-0.0009)*(Weight/FScale);
    end;
    AddRiderSurfaceDelta(Morph,Delta);
  end;
  for I:=0 to App.FdEffects.Count-1 do if App.FdEffects[I].X3DName='RiderSkinSurface'then Exit;
  Eff:=TEffectNode.Create('RiderSkinSurface');Eff.Language:=slGLSL;Eff.UniformMissing:=umIgnore;
  DiffusionField:=TSFNode.Create(Eff,True,'rsDiffusion',[TImageTextureNode]);
  DiffusionField.Value:=SkinDiffusionLut;Eff.AddCustomField(DiffusionField);
  Eff.AddCustomField(TSFFloat.Create(Eff,True,'rsPortrait',Ord(Portrait)));
  Eff.AddCustomField(TSFFloat.Create(Eff,True,'rsCleanPortrait',Ord(Pos('anatomicalportrait',Nm)>0)));
  Eff.AddCustomField(TSFFloat.Create(Eff,True,'rsFaceValid',Ord(FFaceValid and Portrait)));
  Eff.AddCustomField(TSFFloat.Create(Eff,True,'rsGeometricEyes',Ord(FGeometricEyes)));
  MouthField:=TSFFloat.Create(Eff,True,'riderSurfaceAmount',0);Eff.AddCustomField(MouthField);
  if Portrait then begin SetLength(FMouthFields,Length(FMouthFields)+1);FMouthFields[High(FMouthFields)]:=MouthField end;
  Eff.AddCustomField(TSFVec3f.Create(Eff,True,'rsMouth',FMouth));
  Eff.AddCustomField(TSFFloat.Create(Eff,True,'rsHeadSurfaceOffset',FHeadSurfaceOffset));
  FaceField:=TSFVec4f.Create(Eff,True,'rsFace',TVector4.Zero);Eff.AddCustomField(FaceField);
  if Portrait then begin SetLength(FFields,Length(FFields)+1);FFields[High(FFields)]:=FaceField end;
  Eff.AddCustomField(TSFVec3f.Create(Eff,True,'rsEyeL',FEyes[0]));
  Eff.AddCustomField(TSFVec3f.Create(Eff,True,'rsEyeR',FEyes[1]));
  Eff.AddCustomField(TSFVec3f.Create(Eff,True,'rsSkinL',FEyeSkin[0]));
  Eff.AddCustomField(TSFVec3f.Create(Eff,True,'rsSkinR',FEyeSkin[1]));
  Eff.AddCustomField(TSFVec3f.Create(Eff,True,'rsIrisL',FIris[0]));
  Eff.AddCustomField(TSFVec3f.Create(Eff,True,'rsIrisR',FIris[1]));
  V:=TEffectPartNode.Create;V.ShaderType:=stVertex;V.Contents:=RiderSurfaceMotionVS+SkinVS;
  F:=TEffectPartNode.Create;F.ShaderType:=stFragment;F.Contents:=SkinFS;
  Eff.SetParts([V,F]);App.FdEffects.Add(Eff);
end;
constructor TRiderSkin.Create(Root:TX3DNode;Height:Single;const FaceFile:String;GeometricFace:Boolean;GeometricEyes:Boolean);
var Source:TFileStream;Data:TJSONData;Eyes:TJSONArray;I:Integer;
  function Vec(Obj:TJSONData;const Key:String;Linear:Boolean):TVector3;
  var A:TJSONArray;K:Integer;C:Single;
  begin
    A:=TJSONObject(Obj).Arrays[Key];if A.Count<>3 then raise Exception.Create('Invalid face landmark');
    for K:=0 to 2 do begin C:=A.Floats[K];
      if IsNan(C)or IsInfinite(C)then raise Exception.Create('Invalid face coordinate');
      if Linear then begin C:=EnsureRange(C,0,1);if C<=0.04045 then C:=C/12.92 else C:=Power((C+0.055)/1.055,2.4) end;
      Result.Data[K]:=C;
    end;
  end;
begin
  inherited Create;FGeometricFace:=GeometricFace;FGeometricEyes:=GeometricEyes;FScale:=1.8/Max(Height,0.5);FTime:=Random*5.7;
  if FileExists(FaceFile)then begin
    Data:=nil;Source:=nil;
    try
      try
        Source:=TFileStream.Create(FaceFile,fmOpenRead or fmShareDenyWrite);Data:=GetJSON(Source);
        Eyes:=TJSONObject(Data).Arrays['eyes'];if Eyes.Count<>2 then raise Exception.Create('Invalid eyes');
        FMouth:=Vec(Data,'mouth',False);
        FHeadSurfaceOffset:=TJSONObject(Data).Get('surface_offset_y',0.0);
        for I:=0 to 1 do begin
          FEyes[I]:=Vec(Eyes.Items[I],'center',False);
          FEyeSkin[I]:=Vec(Eyes.Items[I],'skin_rgb',True);FIris[I]:=Vec(Eyes.Items[I],'iris_rgb',True);
        end;
        FFaceValid:=True;
      except on E:Exception do FFaceValid:=False end;
    finally Data.Free;Source.Free end;
  end;
  if Root<>nil then Root.EnumerateNodes(TShapeNode,@Visit,False);
  Update(0,0);
end;
procedure TRiderSkin.Update(Dt,Strain:Single;BreathPhase:Double;BreathLoad:Single;Detail:Single);
var Blink,Gaze,OpenMouth:Single;Value:TVector4;I:Integer;
begin
  FTime:=FTime+EnsureRange(Dt,0.0,0.25);if not FFaceValid then Exit;
  if Detail<=0 then begin
    if FDetailActive then begin
      for I:=0 to High(FFields)do FFields[I].Send(TVector4.Zero);
      for I:=0 to High(FMouthFields)do FMouthFields[I].Send(0);
    end;
    FDetailActive:=False;Exit;
  end;
  FDetailActive:=True;
  Blink:=RiderFaceBlink(FTime);
  Gaze:=Sin(FTime*0.31)*Sin(FTime*0.73);
  Value:=Vector4(Blink*Detail,0.0010*Gaze*Detail,0.00035*Sin(FTime*0.43)*Detail,EnsureRange(Strain,0,1));
  for I:=0 to High(FFields)do FFields[I].Send(Value);
  OpenMouth:=0;
  if not FGeometricFace then OpenMouth:=Detail*EnsureRange((BreathLoad-0.20)/1.15,0,1)*(0.68+0.32*(0.5+0.5*Sin(BreathPhase*2*Pi)));
  for I:=0 to High(FMouthFields)do FMouthFields[I].Send(OpenMouth);
end;
procedure TRiderSkin.SetTime(const Value:Double);
begin FTime:=Max(Value,0) end;
procedure ApplyRiderSkin(Root:TX3DNode;Height:Single);
var Skin:TRiderSkin;
begin Skin:=TRiderSkin.Create(Root,Height,'');Skin.Free end;
finalization
  if SkinDiffusionTexture<>nil then begin
    SkinDiffusionTexture.KeepExistingEnd;SkinDiffusionTexture.FreeIfUnused;
  end;
end.
