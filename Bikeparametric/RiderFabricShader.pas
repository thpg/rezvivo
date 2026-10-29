unit RiderFabricShader;
{$mode objfpc}{$H+}
interface
uses RiderShaderSharing, X3DNodes, X3DFields, CastleVectors, CastleImages, RiderGarmentState, RiderGarmentSupport;
type
  TRiderFabric = class
  private
    FBreathFields:array of TSFFloat;
    FScale: Single;
    FGarment:TRiderGarmentParameters;
    FGarmentTexture:TImageTextureNode;
    FConstructionTexture:TImageTextureNode;
    FGarmentFields:array of TSFVec4f;
    FDrapeFields:array of TSFVec4f;
    FRecipe:TGarmentRecipe;
    FAtlas:TRGBAlphaFloatImage; { borrowed from FGarmentTexture }
    FGarmentBlend,FHemPull,FStartHemPull,FAdjustTime:Single;
    FAdjustActive:Boolean;
    FGarmentExplicit:Boolean;
    FGarmentGeneration:Cardinal;
    FGarmentId:Cardinal;
    FLastGarment:TVector4;
    FStretch:TGarmentPanelStretch;
    FStretchValues:TVector4List;
    FStretchFields:array of TMFVec4f;
    procedure UploadGarment(PreviousBlend:Single;Reset:Boolean);
    procedure PublishGarment;
    procedure AddGarmentFields(Eff:TEffectNode;Enabled:Boolean);
    procedure Visit(Node:TX3DNode);
    procedure RefreshRespiratoryShape(Node:TX3DNode);
  public
    constructor Create(Root:TX3DNode;Height:Single);
    destructor Destroy;override;
    procedure ConfigureGarment(const Params:TRiderGarmentParameters;Immediate:Boolean=True);
    procedure RecalculateGarment(PullHem:Boolean=True);
    procedure SetBodySeed(Seed:Cardinal);
    function AdjustReach:Single;
    procedure SetPanelStretch(const Value:TGarmentPanelStretch);
    procedure RefreshRespiration(Root:TX3DNode);
    property Garment:TRiderGarmentParameters read FGarment;
    property PanelStretch:TGarmentPanelStretch read FStretch;
    procedure Update(BreathPhase:Double=0;BreathLoad:Single=0;
      Dt:Single=0);
  end;
{ Attach once, before GPU skinning. Runtime-only material changes. }
procedure ApplyRiderFabric(Root: TX3DNode);

implementation
uses RenderComplexity, SysUtils, Math, CastleRenderOptions,RiderSurfaceMotion,RiderConstructionAtlas;
var NextGarmentId:Cardinal=0;
const
  GarmentCoordinatesGLSL=
    'vec2 rfPanel(vec3 p){'+#10+
    ' vec2 q=vec2(p.x/0.16,(p.z+0.025)/0.11);'+#10+
    ' return vec2(0.5+atan(q.x,q.y)/6.2831853,(p.y-1.0)/0.48);'+#10+
    '}'+#10;
  GarmentStateGLSL=GarmentCoordinatesGLSL+
    'uniform vec4 rfDrape,rfGarment;uniform vec4 rfStretch[9];'+#10+
    'float rfPanelMetric(vec3 p,int offset){'+#10+
    ' vec4 spans=mix(rfStretch[offset],rfStretch[offset+1],smoothstep(1.095,1.22,p.y));'+#10+
    ' spans=mix(spans,rfStretch[offset+2],smoothstep(1.22,1.345,p.y));'+#10+
    ' vec2 q=vec2(p.x/0.16,(p.z+0.025)/0.11);'+#10+
    ' vec4 sides=max(vec4(q.y,q.x,-q.y,-q.x),vec4(0.0));sides*=sides;'+#10+
    ' return dot(spans,sides)/max(dot(q,q),0.01);'+#10+
    '}'+#10+
    'vec3 rfStrain(vec3 p){return vec3(rfPanelMetric(p,0),rfPanelMetric(p,3),rfPanelMetric(p,6));}'+#10+
    'vec2 rfFoldUV(vec3 p){'+#10+
    ' vec2 uv=rfPanel(p);float shear=rfPanelMetric(p,6);'+#10+
    ' uv.x+=clamp(shear,-0.4,0.4)*0.055*sin(uv.y*3.14159265);return uv;'+#10+
    '}'+#10+
    'float rfGain(vec3 p,vec2 crossFold){'+#10+
    ' float lower=1.0-smoothstep(1.13,1.31,p.y);'+#10+
    ' vec2 q=vec2(p.x/0.16,(p.z+0.025)/0.11);float total=max(dot(q,q),0.01);'+#10+
    // A cycling pattern is cut for a bent torso: the back has more material
    // length than the front. Body rest length alone incorrectly pulled even
    // roomy jerseys completely flat. This is rest cut, not a pose gain.
    ' float back=max(-q.y,0.0);float cut=mix(0.020,0.055,lower)*back*back/total+0.012*q.x*q.x/total;'+#10+
    ' float materialLength=1.015+cut+0.045*rfDrape.x+lower*(0.035*rfDrape.y-0.025*rfDrape.z);'+#10+
    ' vec3 strain=rfStrain(p);float across=1.012+0.035*rfDrape.x;'+#10+
    ' vec2 slack=vec2(across-strain.y,materialLength-strain.x);'+#10+
    // Only compression across a fold can sustain that fold. Taking the
    // maximum principal slack kept horizontal folds alive even while the
    // back was stretched, just because the shirt was loose transversely.
    ' crossFold*=inversesqrt(max(dot(crossFold,crossFold),1e-20));'+#10+
    ' float slackAcross=dot(slack,crossFold*crossFold)-strain.z*crossFold.x*crossFold.y;'+#10+
    ' return sqrt(clamp(slackAcross,0.0,0.16)/0.04);'+#10+
    '}'+#10;
  GarmentShapeVS=
    '#define RIDER_GARMENT_SHAPE'+#10+
    'attribute vec3 riderFabricRest;'+#10+
    'uniform sampler2D rfFoldAtlas;'+#10+
    'vec2 rfPanel(vec3 p);'+#10+
    'vec2 rfClothHeights(vec2 uv){'+#10+
    ' vec4 h=texture2D(rfFoldAtlas,vec2(uv.x,clamp(uv.y,0.0,1.0)));'+#10+
    ' return mix(h.xy,h.zw,rfGarment.x);'+#10+
    '}'+#10+
    'void riderGarmentDeform(inout vec3 p,inout vec3 n,mat3 frame){'+#10+
    ' if(rfDrape.w==0.0)return;'+#10+
    ' vec3 rest=riderFabricRest;'+#10+
    ' float lower=(1.0-smoothstep(1.13,1.31,rest.y));'+#10+
    ' float sewn=smoothstep(1.005,1.04,rest.y)*(1.0-smoothstep(1.38,1.455,rest.y));'+#10+
    ' vec2 uv=rfFoldUV(rest);'+#10+
    ' vec2 height=rfClothHeights(uv);'+#10+
    ' vec2 dh=vec2(rfClothHeights(uv+vec2(0.001953125,0)).x-height.x,'+#10+
    '               rfClothHeights(uv+vec2(0,0.0026041667)).x-height.x);'+#10+
    ' vec2 across=dh*vec2(512.0/0.90,384.0/0.48);'+#10+
    ' if(dot(across,across)<1e-16)across=vec2(0,1);'+#10+
    ' float gain=rfGain(rest,across);'+#10+
    ' float broad=height.x*gain;'+#10+
    ' float clearance=0.008*max(rfDrape.x,0.0)*lower*sewn*min(gain,1.0);'+#10+
    ' vec3 supportNormal=n;'+#10+
    ' vec3 outward=normalize(frame*vec3(rest.x/(0.16*0.16),0,(rest.z+0.025)/(0.11*0.11)));'+#10+
    ' p+=outward*((broad+clearance)/rfDrape.w);'+#10+
    ' p-=frame*vec3(0,1,0)*(sewn*lower*(0.010*rfDrape.y+0.006*rfDrape.z)/rfDrape.w);'+#10+
    ' // The broad height changes positions AND normals; fine atlas relief is'+#10+
    ' // reserved for the fragment stage, so neither band is applied twice.'+#10+
    ' dh*=vec2(512.0,384.0/0.48)*gain;'+#10+
    ' vec2 q=vec2(rest.x/0.16,(rest.z+0.025)/0.11);'+#10+
    ' float den=max(dot(q,q),0.05)*6.2831853;'+#10+
    ' vec3 gradient=vec3(dh.x*q.y/(0.16*den),dh.y,-dh.x*q.x/(0.11*den));'+#10+
    ' gradient=frame*gradient;gradient-=supportNormal*dot(supportNormal,gradient);'+#10+
    ' n=normalize(supportNormal-gradient);'+#10+
    '}'+#10;
  FabricVS =
    'attribute vec2 riderFabricUV;' + #10 +
    'attribute vec3 riderFabricMetric;' + #10 + '#ifndef GL_ES' + #10 + 'uniform mat4 castle_ModelViewMatrix;' + #10 + '#endif' + #10 + '' + #10 +
    'varying vec2 rfUV;' + #10 +
    'varying vec3 rfPosition;' + #10 +
    'varying vec3 rfRestMetric;' + #10 +
    'void PLUG_vertex_eye_space(const vec4 v, const vec3 n) {' + #10 +
    '  rfPosition=riderFabricRest;rfUV=riderFabricUV;' + #10 +
    '  rfRestMetric=mat3(castle_ModelViewMatrix)*riderFabricMetric;' + #10 +
    '}';
  FabricFS = GarmentStateGLSL+
    'uniform float rz_complexity;' + #10 +
    'varying vec3 rfPosition;' + #10 +
    'varying vec3 rfRestMetric;' + #10 +
    'varying vec2 rfUV;uniform float rfRegion;' + #10 +
    'uniform vec4 rfProfile; // spacing, height, roughness, weave kind' + #10 +
    'uniform sampler2D rfFoldAtlas,rfConstruction;' + #10 +
    'vec3 rfTangent=vec3(0.0);float rfRoughness=0.6;' + #10 +
    'float rfDetail=0.0,rfMeso=0.0,rfBibsPattern=0.0,rfSeam=0.0,rfPanelTone=0.0;' + #10 +
    'float rfBell(float x){return exp2(-1.442695*x*x);}' + #10 +
    'vec2 rfCrossFold(vec2 uv,float h){' + #10 +
    ' vec2 dx=dFdx(uv)*vec2(0.90,0.48),dy=dFdy(uv)*vec2(0.90,0.48);' + #10 +
    ' float det=dx.x*dy.y-dx.y*dy.x;' + #10 +
    ' vec2 g=vec2(dy.y*dFdx(h)-dx.y*dFdy(h),dx.x*dFdy(h)-dy.x*dFdx(h));' + #10 +
    ' if(abs(det)<1e-12 || dot(g,g)<1e-24 || abs(dx.x)+abs(dy.x)>0.1)return vec2(0,1);' + #10 +
    ' return g;' + #10 +
    '}' + #10 +
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
    '  float compression=0.0;' + #10 +
    '  if(rfRegion>=0.5 && rfRegion<2.5){' + #10 +
    '  vec3 dx=dFdx(v.xyz),dy=dFdy(v.xyz),rx=dFdx(rfRestMetric),ry=dFdy(rfRestMetric);' + #10 +
    '  float e=dot(rx,rx),f=dot(rx,ry),g=dot(ry,ry),area=e*g-f*f;' + #10 +
    '  if(area>1e-8*e*g && e*g>1e-24){' + #10 +
    '    float E=dot(dx,dx),F=dot(dx,dy),G=dot(dy,dy);' + #10 +
    '    float trace=(E*g+G*e-2.0*F*f)/area;' + #10 +
    '    float determinant=max(E*G-F*F,0.0)/area;' + #10 +
    '    float stretch=sqrt(max(0.5*(trace-sqrt(max(trace*trace-4.0*determinant,0.0))),0.0));' + #10 +
    '    compression=smoothstep(0.025,0.22,1.0-stretch);' + #10 +
    '  }' + #10 +
    '  }' + #10 +
    '  rfDetail=rfWeave(rfUV);' + #10 +
    '  float h=rfDetail*rfProfile.y;' + #10 +
    '  vec3 p=rfPosition;float fold=0.0,compressedFold=0.0,rfGarmentGain=1.0;float ax=abs(p.x);' + #10 +
    '  if(rfRegion<2.5){' + #10 +
    '    vec2 chart=rfPanel(p);float offset=0.0,rows=512.0;' + #10 +
    '    if(rfRegion>0.5 && rfRegion<1.5){' + #10 +
    '      vec3 a=vec3(ax,p.y,p.z)-vec3(0.165001,1.434600,-0.084599);' + #10 +
    '      vec3 axis=normalize(vec3(0.283588,-0.039295,-0.017460));' + #10 +
    '      vec3 up=normalize(vec3(0,1,0)-axis*axis.y);' + #10 +
    '      chart=vec2(0.5+atan(dot(a,cross(axis,up)),dot(a,up))/6.2831853,dot(a,axis)/0.30);offset=512.0;rows=256.0;' + #10 +
    '    }else if(rfRegion>1.5){chart.y=(p.y-0.65)/0.39;offset=768.0;rows=256.0;}' + #10 +
    '    vec2 cuv=vec2(chart.x,(offset+0.5+clamp(chart.y,0.0,1.0)*(rows-1.0))/1024.0);' + #10 +
    '    vec4 construction=texture2D(rfConstruction,cuv);' + #10 +
    '    h+=dot(construction.rg,vec2(256.0,1.0))*(0.008/257.0)-0.002;' + #10 +
    '    rfSeam=construction.b;rfPanelTone=construction.a-0.5;' + #10 +
    '  }' + #10 +
    // The next visible scale belongs to yarn bundles in the panel UVs.
    // A body-space product of sine waves painted centimetre-wide cloudy
    // patches onto the bibs, unrelated to the fabric construction.
    '  vec2 yarn=rfUV/(rfProfile.x*3.7);' + #10 +
    '  rfMeso=0.6*rfFold(6.2831853*yarn.x)+0.4*rfFold(6.2831853*yarn.y+0.7);' + #10 +
    '  if(rfRegion<0.5){' + #10 +
    // Geometry already carries the broad band. This is the residual fine
    // field in the SAME periodic material coordinates and strain state.
    '    vec2 atlasUV=rfFoldUV(p);' + #10 +
    '    vec4 layouts=texture2D(rfFoldAtlas,vec2(atlasUV.x,clamp(atlasUV.y,0.0,1.0)));' + #10 +
    '    fold=mix(layouts.y,layouts.w,rfGarment.x);' + #10 +
    '    rfGarmentGain=rfGain(p,rfCrossFold(atlasUV,fold));' + #10 +
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
    '    float padSeam=rfRidge(edge+0.001,0.0035);rfSeam=max(rfSeam,padSeam);' + #10 +
    '    h+=0.0006*padSeam+0.00025*rfRidge(edge+0.001-zigzag,0.00055);' + #10 +
    '    rfBibsPattern=rfFold(6.2831853*(rfUV.x+0.38*rfUV.y)/0.007)*(0.5+0.5*rfFold(6.2831853*rfUV.y/0.014));' + #10 +
    '    h+=0.000007*rfBibsPattern;' + #10 +
    '    float hip=smoothstep(0.81,0.87,p.y)*(1.0-smoothstep(0.98,1.025,p.y))*smoothstep(0.015,0.075,p.z);' + #10 +
    '    float hipLine=p.y+0.22*ax;' + #10 +
    '    compressedFold=0.00065*hip*(rfRidge(hipLine-0.898,0.012)-0.45*rfRidge(hipLine-0.931,0.017));' + #10 +
    // No painted crotch AO or rest-pose buttock crease. As the thigh rises,
    // those patches remain on the cloth and read as dirt. The deformed
    // surface supplies the large-scale volume; keep only weave and stitching.
    '  }' + #10 +
    '  h+=rfProfile.y*0.65*rfMeso;' + #10 +
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
    '  vec2 dh=vec2(dFdx(h),dFdy(h))+rfGarmentGain*vec2(dFdx(fold),dFdy(fold))+compression*vec2(dFdx(compressedFold),dFdy(compressedFold));' + #10 +
    '  vec3 grad=r1*dh.x+r2*dh.y;' + #10 +
    '  if(det*det>1e-12*dot(dpdx,dpdx)*dot(dpdy,dpdy)) {' + #10 +
    '    grad/=det; grad*=min(1.0,0.45/max(length(grad),1e-8));' + #10 +
    '    n=normalize(N-grad);' + #10 +
    '  }' + #10 +
    '}' + #10 +
    'void PLUG_main_texture_apply(inout vec4 c,const vec3 n) {' + #10 +
    '  c.rgb*=1.0+0.032*rfDetail+0.014*rfMeso+0.027*rfBibsPattern+0.09*rfSeam-0.25*rfPanelTone;' + #10 +
    '}' + #10 +
    'void PLUG_material_metallic_roughness(inout float m,inout float r) {' + #10 +
    '  m=0.0; r=clamp(rfProfile.z+0.025*rfDetail+0.022*rfMeso+0.020*rfBibsPattern+0.05*rfSeam+rfPanelTone,0.38,0.96);' + #10 +
    '  rfRoughness=r;' + #10 +
    '}' + #10 +
    // Integrated Charlie/Neubelt lobe for constant incident radiance, fitted
    // over NdotV=0..1 and perceptual roughness=.5..1 (the direct lobe's clamp).
    // Unlike a GGX DFG this integrates the actual cloth BRDF. Max absolute
    // error <.005 against independent hemisphere quadrature; see
    // tests/RiderFabricLightingTest.py. Polynomial: no LUT/texture or pass.
    'float rfCharlieIntegral(float nv,float roughness){' + #10 +
    '  float x=sqrt(sqrt(clamp(nv,0.0,1.0)));' + #10 +
    '  float y=2.0*clamp(roughness,0.5,1.0)-1.0;' + #10 +
    '  float c0=((-0.178859651*y+0.509647210)*y-0.631971288)*y+0.933185148;' + #10 +
    '  float c1=((0.023797705*y-0.093194898)*y+0.101566756)*y+0.062359660;' + #10 +
    '  float c2=((-0.325338387*y+1.004243195)*y-1.029499514)*y-0.121617661;' + #10 +
    '  float c3=((2.127296090*y-5.764811133)*y+5.894266322)*y-2.645058287;' + #10 +
    '  float c4=((-1.669714823*y+4.346960509)*y-4.202342169)*y+1.804028470;' + #10 +
    '  return clamp((((c4*x+c3)*x+c2)*x+c1)*x+c0,0.0,1.0);' + #10 +
    '}' + #10 +
    'float rfFibreStrength(){return mix(0.75,0.90,smoothstep(0.50,0.85,rfProfile.z));}' + #10 +
    'vec3 rfFibreColor(vec3 linearDiffuse){return sqrt(clamp(linearDiffuse,vec3(0.0),vec3(1.0)));}' + #10 +
    'void PLUG_rider_environment_surface(inout vec3 diff,inout vec3 spec,const vec3 diffuseColor,const vec3 N,const vec3 V,const vec3 irradiance){' + #10 +
    '  if(rfRegion>4.5)return;' + #10 +
    '  float strength=rfFibreStrength();' + #10 +
    '  float dg=rfCharlieIntegral(max(dot(N,V),0.0),rfProfile.z);' + #10 +
    '  vec3 fibre=rfFibreColor(diffuseColor);' + #10 +
    // The broad fibre lobe sees the diffuse sky hemisphere, not a hard-surface
    // reflection of its horizon. Irradiance/pi is its mean incident radiance.
    // The base GGX and dyed fibre share energy, exactly as for direct light.
    '  diff*=1.0-0.04*strength;' + #10 +
    '  spec=spec*(1.0-strength)+fibre*(0.45*strength*dg)*irradiance/3.14159265;' + #10 +
    '}' + #10 +
    // Charlie NDF (Estevez/Kulla 2017), Neubelt visibility; see Filament cloth model.
    // A modest fiber lobe suits cycling synthetics, rather than velvet.
    'void PLUG_physical_light_surface(inout vec3 diff,inout vec3 spec,const vec3 L,const vec3 N,const vec3 V) {' + #10 +
    '  if(rfRegion>4.5)return;' + #10 +
    '  float nl=max(dot(N,L),0.0),nv=max(dot(N,V),0.0);' + #10 +
    '  if(nl<=0.0 || nv<=0.0)return;' + #10 +
    '  vec3 H=L+V;H*=inversesqrt(max(dot(H,H),1e-8));float nh=clamp(dot(N,H),0.0,1.0);' + #10 +
    // Tight synthetic bibs reflect along the knit, rather than forming one
    // uniformly blurred highlight. Anisotropic GGX + correlated Smith masking
    // (equations documented in Filament, section Anisotropic specular BRDF).
    // Replace the isotropic lobe; adding another would brighten black fabric.
    '  if(rfRegion>1.5 && rfRegion<2.5 && rz_complexity>=2.5){' + #10 +
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
    '  float strength=rfFibreStrength();' + #10 +
    '  vec3 fibre=rfFibreColor(diff*3.14159265);' + #10 +
    '  diff*=1.0-0.04*strength;spec=spec*(1.0-strength)+fibre*(0.45*strength*D*visibility);' + #10 +
    '}';
procedure TRiderFabric.Visit(Node: TX3DNode);
var Sh:TShapeNode; App:TAppearanceNode; Mat:TPhysicalMaterialNode;
  Geo:TAbstractComposedGeometryNode; Coord:TCoordinateNode;
  Attr,UVAttr,Metric:TFloatVertexAttributeNode; Eff:TEffectNode; V,F:TEffectPartNode;
  Profile:TVector4; P,Q:TVector3; Nm:String; I,J,A,B:Integer;
  UVNode:TX3DNode;UV:TTextureCoordinateNode;D:TVector2;
  SumWorld,SumUV:Double;UVScale,Region:Single;Morph:TFloatVertexAttributeNode;Breath:TSFFloat;
  procedure AddRestCoordinates;
  var K:Integer;
  begin
    for K:=0 to Geo.FdAttrib.Count-1 do
      if(Geo.FdAttrib[K]is TFloatVertexAttributeNode)and
        (TFloatVertexAttributeNode(Geo.FdAttrib[K]).NameField='riderFabricRest')then Exit;
    Attr:=TFloatVertexAttributeNode.Create;Attr.NameField:='riderFabricRest';Attr.NumComponents:=3;
    for K:=0 to Coord.FdPoint.Count-1 do begin
      P:=Coord.FdPoint.Items[K]*FScale;
      Attr.FdValue.Items.Add(P.X);Attr.FdValue.Items.Add(P.Y);Attr.FdValue.Items.Add(P.Z);
    end;
    Geo.FdAttrib.Add(Attr);
  end;
begin
  Sh:=TShapeNode(Node);
  if not(Sh.Appearance is TAppearanceNode)or
     not(Sh.Appearance.Material is TPhysicalMaterialNode)or
     not(Sh.Geometry is TAbstractComposedGeometryNode)then Exit;
  App:=TAppearanceNode(Sh.Appearance);Mat:=TPhysicalMaterialNode(App.Material);
  Nm:=LowerCase(App.X3DName+' '+Mat.X3DName);
  { Trim and zipper teeth must follow the same respiratory field as the fabric.
    Their material can also be used on shoes, which receive zero deltas. }
  if(Pos('kitlogo',LowerCase(Sh.X3DName))=1)or
    ((Pos('binding -',Nm)>0)and(Pos('part_jerseybinding',Nm)=0))or
    (Pos('zipper hardware',Nm)>0)then begin
    Geo:=TAbstractComposedGeometryNode(Sh.Geometry);
    if not(Geo.Coord is TCoordinateNode)then Exit;
    Coord:=TCoordinateNode(Geo.Coord);AddRestCoordinates;Morph:=AddRiderSurfaceAttribute(Geo);
    if Morph.FdValue.Count=0 then RefreshRiderRespiration(Geo,FScale);
    for I:=0 to App.FdEffects.Count-1 do
      if App.FdEffects[I].X3DName='RiderGarmentDetailBreathing'then Exit;
    Eff:=TEffectNode.Create('RiderGarmentDetailBreathing');Eff.Language:=slGLSL;Eff.UniformMissing:=umIgnore;
    Breath:=TSFFloat.Create(Eff,True,'riderSurfaceAmount',0);Eff.AddCustomField(Breath);
    SetLength(FBreathFields,Length(FBreathFields)+1);FBreathFields[High(FBreathFields)]:=Breath;
    AddGarmentFields(Eff,True);
    V:=TEffectPartNode.Create;V.ShaderType:=stVertex;V.Contents:='#define RIDER_SURFACE_RESPIRATION'+#10+GarmentStateGLSL+GarmentShapeVS+RiderSurfaceMotionVS;
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
  AddRestCoordinates;
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
  if Morph.FdValue.Count=0 then begin
    if Region<1.5 then RefreshRiderRespiration(Geo,FScale)
    else for I:=0 to Coord.FdPoint.Count-1 do
      AddRiderSurfaceSample(Morph,TVector3.Zero,Vector3(0,0,1),1/FScale,False);
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
  AddGarmentFields(Eff,Region<0.5);
  V:=TEffectPartNode.Create;V.ShaderType:=stVertex;V.Contents:='#define RIDER_SURFACE_RESPIRATION'+#10+GarmentStateGLSL+GarmentShapeVS+RiderSurfaceMotionVS+FabricVS;
  F:=TEffectPartNode.Create;F.ShaderType:=stFragment;F.Contents:=FabricFS;
  Eff.SetParts([V,F]);ShareRiderEffect(Eff);App.FdEffects.Add(Eff);
end;

procedure TRiderFabric.RefreshRespiratoryShape(Node:TX3DNode);
var Sh:TShapeNode;I:Integer;Eff:TEffectNode;Region:TSFFloat;
begin
  Sh:=TShapeNode(Node);
  if(Sh.Appearance=nil)or not(Sh.Geometry is TAbstractComposedGeometryNode)then Exit;
  for I:=0 to Sh.Appearance.FdEffects.Count-1 do begin
    if not(Sh.Appearance.FdEffects[I]is TEffectNode)then Continue;
    Eff:=TEffectNode(Sh.Appearance.FdEffects[I]);
    if Eff.X3DName='RiderGarmentDetailBreathing'then begin
      RefreshRiderRespiration(TAbstractComposedGeometryNode(Sh.Geometry),FScale);Exit;
    end;
    if Eff.X3DName='RiderProceduralFabric'then begin
      Region:=TSFFloat(Eff.Field('rfRegion'));
      if(Region<>nil)and(Region.Value<1.5)then
        RefreshRiderRespiration(TAbstractComposedGeometryNode(Sh.Geometry),FScale);
      Exit;
    end;
  end;
end;
procedure TRiderFabric.RefreshRespiration(Root:TX3DNode);
begin
  { Only a body edit. The tangent basis must agree with the current morph's
    normals, not normals left over from the authoring mannequin. }
  if Root<>nil then Root.EnumerateNodes(TShapeNode,@RefreshRespiratoryShape,False);
end;
procedure TRiderFabric.AddGarmentFields(Eff:TEffectNode;Enabled:Boolean);
var AtlasField:TSFNode;
begin
  AtlasField:=TSFNode.Create(Eff,True,'rfFoldAtlas',[TImageTextureNode]);
  AtlasField.Value:=FGarmentTexture;Eff.AddCustomField(AtlasField);
  AtlasField:=TSFNode.Create(Eff,True,'rfConstruction',[TImageTextureNode]);
  AtlasField.Value:=FConstructionTexture;Eff.AddCustomField(AtlasField);
  SetLength(FStretchFields,Length(FStretchFields)+1);
  FStretchFields[High(FStretchFields)]:=TMFVec4f.Create(Eff,True,'rfStretch',[]);
  FStretchFields[High(FStretchFields)].Items.Assign(FStretchValues);
  Eff.AddCustomField(FStretchFields[High(FStretchFields)]);
  SetLength(FGarmentFields,Length(FGarmentFields)+1);
  FGarmentFields[High(FGarmentFields)]:=TSFVec4f.Create(Eff,True,'rfGarment',Vector4(1,0,FGarment.Ease,0));
  Eff.AddCustomField(FGarmentFields[High(FGarmentFields)]);
  SetLength(FDrapeFields,Length(FDrapeFields)+1);
  FDrapeFields[High(FDrapeFields)]:=TSFVec4f.Create(Eff,True,'rfDrape',Vector4(FGarment.Ease,FGarment.LengthEase,0,FScale*Ord(Enabled)));
  Eff.AddCustomField(FDrapeFields[High(FDrapeFields)]);
end;

constructor TRiderFabric.Create(Root:TX3DNode;Height:Single);
var Props:TTexturePropertiesNode;I:Integer;
begin
  inherited Create;FScale:=1.8/Max(Height,0.5);
  FStretchValues:=TVector4List.Create;
  FStretch:=RelaxedGarmentStretch;
  for I:=Low(FStretch)to High(FStretch)do FStretchValues.Add(FStretch[I]);
  FConstructionTexture:=CreateRiderConstructionTexture;FConstructionTexture.KeepExistingBegin;
  Inc(NextGarmentId);FGarmentId:=NextGarmentId;
  FGarment:=DefaultRiderGarment;PrepareGarmentRecipe(FGarment,FRecipe);
  FGarmentBlend:=1;
  FGarmentTexture:=TImageTextureNode.Create;FGarmentTexture.KeepExistingBegin;
  Props:=TTexturePropertiesNode.Create;Props.GUITexture:=True;Props.GenerateMipMaps:=True;
  Props.FdMinificationFilter.Value:='AVG_PIXEL_AVG_MIPMAP';Props.FdMagnificationFilter.Value:='AVG_PIXEL';
  FGarmentTexture.FdTextureProperties.Value:=Props;
  FGarmentTexture.RepeatS:=True;FGarmentTexture.RepeatT:=False;UploadGarment(1,True);
  if Root=nil then Exit;
  Root.EnumerateNodes(TShapeNode,@Visit,False);
end;
destructor TRiderFabric.Destroy;
begin
  if FGarmentTexture<>nil then begin FGarmentTexture.KeepExistingEnd;FGarmentTexture.FreeIfUnused end;
  if FConstructionTexture<>nil then begin FConstructionTexture.KeepExistingEnd;FConstructionTexture.FreeIfUnused end;
  FStretchValues.Free;
  inherited;
end;
procedure TRiderFabric.UploadGarment(PreviousBlend:Single;Reset:Boolean);
const W=GarmentAtlasWidth;H=GarmentAtlasHeight;
var Img:TRGBAlphaFloatImage;X,Y:Integer;Broad,Fine:TGarmentHeights;V,Old:TVector4;
begin
  BakeGarmentHeight(FRecipe,Broad,Fine);
  Img:=TRGBAlphaFloatImage.Create(W,H);
  try
    for Y:=0 to H-1 do begin
      for X:=0 to W-1 do begin
        V.Z:=Broad[Y*W+X];V.W:=Fine[Y*W+X];
        if Reset or(FAtlas=nil)then begin V.X:=V.Z;V.Y:=V.W end
        else begin
          Old:=PVector4(FAtlas.PixelPtr(X,Y))^;
          V.X:=Old.X*(1-PreviousBlend)+Old.Z*PreviousBlend;
          V.Y:=Old.Y*(1-PreviousBlend)+Old.W*PreviousBlend;
        end;
        PVector4(Img.PixelPtr(X,Y))^:=V;
      end;
    end;
    Inc(FGarmentGeneration);
    FGarmentTexture.LoadFromImage(Img,True,'castle-internal:/rider/garment-panel-v3/'+IntToStr(FGarmentId)+'-'+IntToStr(FGarmentGeneration));
    FAtlas:=Img;
    Img:=nil;
  finally Img.Free end;
end;
procedure TRiderFabric.ConfigureGarment(const Params:TRiderGarmentParameters;Immediate:Boolean);
var PreviousBlend:Single;
begin
  if Immediate and SameRiderGarment(FGarment,NormalizeRiderGarment(Params))then begin
    FGarmentExplicit:=True;Exit;
  end;
  PreviousBlend:=GarmentSmooth(FGarmentBlend);
  FStartHemPull:=FHemPull;
  FAdjustActive:=not Immediate and Params.Adjusted;FAdjustTime:=0;
  FGarmentExplicit:=True;FGarment:=NormalizeRiderGarment(Params);
  PrepareGarmentRecipe(FGarment,FRecipe);
  if Immediate then begin FGarmentBlend:=1;FHemPull:=Ord(FGarment.Adjusted)end
  else FGarmentBlend:=0;
  UploadGarment(PreviousBlend,Immediate);
  PublishGarment;
end;
function TRiderFabric.AdjustReach:Single;
begin
  Result:=0;if not FAdjustActive then Exit;
  Result:=GarmentSmooth(FAdjustTime/0.75)*GarmentSmooth((2.8-FAdjustTime)/0.8);
end;
procedure TRiderFabric.SetBodySeed(Seed:Cardinal);
begin
  if FGarmentExplicit or(FGarment.Seed=Seed)then Exit;
  ConfigureGarment(DefaultRiderGarment(Seed));FGarmentExplicit:=False;
end;
procedure TRiderFabric.RecalculateGarment(PullHem:Boolean);
var P:TRiderGarmentParameters;
begin
  P:=FGarment;Inc(P.Revision);P.Adjusted:=PullHem;
  ConfigureGarment(P,False);
end;
procedure TRiderFabric.Update(BreathPhase:Double;BreathLoad:Single;
  Dt:Single);
var I:Integer;Expansion:Single;
begin
  if FAdjustActive then begin
    FAdjustTime:=FAdjustTime+EnsureRange(Dt,0,0.25);
    FGarmentBlend:=GarmentSmooth((FAdjustTime-0.75)/0.9);
    if FAdjustTime>=2.8 then FAdjustActive:=False;
  end else FGarmentBlend:=Min(1,FGarmentBlend+EnsureRange(Dt,0,0.25)/1.25);
  FHemPull:=FStartHemPull+(Ord(FGarment.Adjusted)-FStartHemPull)*GarmentSmooth(FGarmentBlend);
  PublishGarment;
  Expansion:=(0.5+0.5*Sin(BreathPhase*2*Pi))*(0.25+0.75*EnsureRange(BreathLoad/1.5,0,1));
  for I:=0 to High(FBreathFields)do FBreathFields[I].Send(Expansion);

end;
procedure TRiderFabric.SetPanelStretch(const Value:TGarmentPanelStretch);
var I:Integer;Changed:Boolean;
begin
  Changed:=False;
  for I:=Low(FStretch)to High(FStretch)do if not TVector4.Equals(Value[I],FStretch[I])then Changed:=True;
  if not Changed then Exit;
  FStretch:=Value;
  for I:=Low(FStretch)to High(FStretch)do FStretchValues[I]:=Value[I];
  for I:=0 to High(FStretchFields)do FStretchFields[I].Send(FStretchValues);
end;
procedure TRiderFabric.PublishGarment;
var I:Integer;G,D:TVector4;
begin
  G:=Vector4(GarmentSmooth(FGarmentBlend),FHemPull,FGarment.Ease,FGarment.LengthEase);
  if not TVector4.Equals(G,FLastGarment)then begin
    FLastGarment:=G;
    for I:=0 to High(FGarmentFields)do FGarmentFields[I].Send(G);
  end;
  for I:=0 to High(FDrapeFields)do begin
    D:=Vector4(FGarment.Ease,FGarment.LengthEase,FHemPull,FDrapeFields[I].Value.W);
    if not TVector4.Equals(D,FDrapeFields[I].Value)then FDrapeFields[I].Send(D);
  end;
end;
procedure ApplyRiderFabric(Root:TX3DNode);
var C:TRiderFabric;
begin
  C:=TRiderFabric.Create(Root,1.8);C.Free;
end;
end.
