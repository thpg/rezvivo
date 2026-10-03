unit RiderHairMaterial;
{$mode objfpc}{$H+}
interface
function RiderHairVertexShader:String;
function RiderHairFragmentShader:String;
function RiderHairLightShader:String;
implementation
uses SysUtils, RiderHairData;
function RiderHairVertexShader:String;
begin
  Result:=
    'attribute vec4 riderHairBind;'+#10+
    'attribute vec2 riderHairUV;varying vec2 rhUV;varying vec3 rhRestPosition;'+#10+
    'varying vec3 rhSurface;'+#10+
    'attribute vec3 riderHairRest,riderHairGuide,riderHairStrand,riderHairHelmet;'+#10+
    'uniform vec3 rhGuides['+IntToStr(HairPointCount)+'];'+#10+
    'uniform float rhHelmet,rhStyle; uniform mat3 castle_NormalMatrix;'+#10+
    'varying vec3 rhFlow; varying vec4 rhParam;'+#10+
    'vec3 rhPosedFlow;'+#10+
    'vec3 rhRotate(vec3 p,vec3 a,vec3 b) {'+#10+
    ' vec3 v=cross(a,b);float c=clamp(dot(a,b),-1.0,1.0);'+#10+
    ' return p+cross(v,p)+cross(v,cross(v,p))/max(1.0+c,0.08);'+#10+
    '}'+#10+
    'void PLUG_vertex_object_space_change(inout vec4 p,inout vec3 n) {'+#10+
    ' rhSurface=p.xyz;'+#10+
    ' rhPosedFlow=riderHairStrand;'+#10+
    ' if(riderHairBind.x>=0.0) {'+#10+
    '  float s=min(riderHairBind.y,6.9999);int i=int(riderHairBind.x+floor(s)+0.5);'+#10+
    '  vec3 a=rhGuides[i],b=rhGuides[i+1];'+#10+
    '  int lo=int(riderHairBind.x+0.5),hi=lo+7;'+#10+
    '  vec3 t0=normalize(b-rhGuides[max(i-1,lo)]+vec3(1e-9,0.0,0.0));'+#10+
    '  vec3 t1=normalize(rhGuides[min(i+2,hi)]-a+vec3(1e-9,0.0,0.0));'+#10+
    '  vec3 flow=normalize(mix(t0,t1,fract(s)));'+#10+
    '  vec3 old=normalize(riderHairGuide);'+#10+
    '  vec3 offset=p.xyz-riderHairRest+rhHelmet*riderHairHelmet;'+#10+
    // Keep the rooted cross-section fixed, even when the first free guide
    // segment bends. Rotating it around the guide pulled lobes off the scalp.
    '  float bend=smoothstep(0.0,0.75,s);'+#10+
    '  p.xyz=mix(a,b,fract(s))+mix(offset,rhRotate(offset,old,flow),bend);'+#10+
    '  n=normalize(rhRotate(n,old,flow));'+#10+
    '  rhPosedFlow=normalize(rhRotate(riderHairStrand,old,flow));'+#10+
    ' } else if(abs(rhStyle-3.0)<0.1||abs(rhStyle-7.0)<0.1){'+#10+
    '  float lump=sin(p.x*147.0+p.z*61.0)*sin(p.y*191.0-p.z*127.0);'+#10+
    '  p.xyz+=n*(0.003+0.001*lump)*(1.0-0.8*rhHelmet);'+#10+
    ' }'+#10+
    '}'+#10+
    'void PLUG_vertex_eye_space(const vec4 v,const vec3 n) {'+#10+
    ' rhFlow=castle_NormalMatrix*rhPosedFlow;rhParam=riderHairBind;rhUV=riderHairUV;rhRestPosition=riderHairRest;'+#10+
    '}';
end;
function RiderHairFragmentShader:String;
begin
  Result:=
    'varying vec3 rhFlow;varying vec4 rhParam;'+#10+
    'varying vec2 rhUV;varying vec3 rhRestPosition;uniform sampler2D rhAtlas;'+#10+
    'varying vec3 rhSurface;uniform float rhClothHat;'+#10+
    'uniform vec3 rhColor;uniform float rhDetail,rhStyle;'+#10+
    'vec3 rhTangent=vec3(0.0,1.0,0.0);vec3 rhAlbedo;float rhDensity=1.0;'+#10+
    'float rhCurl(){return max(1.0-step(0.1,abs(rhStyle-3.0)),1.0-step(0.1,abs(rhStyle-7.0)));}'+#10+
    'float rhHash(vec3 p){p=fract(p*vec3(0.1031,0.1030,0.0973));p+=dot(p,p.yxz+33.33);return fract((p.x+p.y)*p.z);}'+#10+
    'float rhNoise(vec3 p){vec3 i=floor(p),u=fract(p);u=u*u*(3.0-2.0*u);'+#10+
    ' return mix(mix(mix(rhHash(i),rhHash(i+vec3(1,0,0)),u.x),mix(rhHash(i+vec3(0,1,0)),rhHash(i+vec3(1,1,0)),u.x),u.y),'+#10+
    ' mix(mix(rhHash(i+vec3(0,0,1)),rhHash(i+vec3(1,0,1)),u.x),mix(rhHash(i+vec3(0,1,1)),rhHash(i+vec3(1,1,1)),u.x),u.y),u.z);}'+#10+
    'float rhScalpRelief(){return rhNoise(rhRestPosition*155.0+vec3(5,17,11));}'+#10+
    'void PLUG_fragment_eye_space(const vec4 v,inout vec3 n) {'+#10+
    ' rhTangent=normalize(rhFlow+vec3(1e-7,0.0,0.0));'+#10+
    ' n=normalize(n);'+#10+
    ' {'+#10+
    '  float h=rhParam.x>=0.0?texture2D(rhAtlas,rhUV).r*0.00020:rhScalpRelief()*rhCurl()*0.0006;vec3 dx=dFdx(v.xyz),dy=dFdy(v.xyz);'+#10+
    '  vec3 a=cross(dy,n),b=cross(n,dx);float det=dot(dx,a);'+#10+
    '  if(det*det>1e-12*dot(dx,dx)*dot(dy,dy)){vec3 g=(a*dFdx(h)+b*dFdy(h))/det;n=normalize(n-g*min(1.0,0.22/max(length(g),1e-6)));}'+#10+
    ' }'+#10+
    '}'+#10+
    'void PLUG_main_texture_apply(inout vec4 c,const vec3 n) {'+#10+
    // Same polar hem as build_head_styles.shell; a low horizontal cut left
    // a visible bald strip between the newly fitted cap and the rear hair.
    ' if(rhClothHat>0.5){vec3 q=rhSurface-vec3(0.0,0.065,-0.003);'+#10+
    '  float radial=max(length(q.xz),0.001),front=q.z/radial;'+#10+
    '  if(atan(radial,q.y)<1.48+0.16*(1.0-front)-0.015)discard;}'+#10+
    ' float shade=0.9;'+#10+
    ' if(rhParam.x<0.0) {'+#10+
    '  vec3 p=rhRestPosition-vec3(0.0,0.065,-0.003);'+#10+
    '  float az=atan(p.x,p.z),front=p.z/max(length(p.xz),1e-8);'+#10+
    '  float hairline=-0.038+0.072*smoothstep(-0.75,0.15,front)+0.080*smoothstep(0.25,0.85,front);'+#10+
    '  float ear=smoothstep(0.054,0.069,abs(rhRestPosition.x))*(1.0-smoothstep(0.016,0.042,abs(rhRestPosition.z-0.026)));'+#10+
    '  hairline=max(hairline,mix(hairline,0.083,ear));'+#10+
    '  hairline+=0.00065*(sin(az*35.0)+0.25*sin(az*113.0));'+#10+
    '  float edge=max(fwidth(rhRestPosition.y-hairline),0.00015);'+#10+
    '  c.a=smoothstep(-edge,edge,rhRestPosition.y-hairline);if(c.a<0.5)discard;'+#10+
    '  float strand=atan(p.x,p.z)*42.0+sin(p.y*45.0)*0.6;'+#10+
    '  float fade=exp2(-4.0*fwidth(strand)*fwidth(strand));'+#10+
    '  shade=0.69+0.10*sin(strand*6.283185)*fade;'+#10+
    '  shade=mix(shade,0.41+0.58*rhScalpRelief(),rhCurl());'+#10+
    ' }'+#10+
    ' else {'+#10+
    '  vec4 atlas=texture2D(rhAtlas,rhUV);'+#10+
    // The atlas already has dense roots and sparse tips. An additional root
    // fade erased the first centimetres of long tails at their attachment.
    '  float coverage=mix(1.0,atlas.a,rhParam.z);float edge=max(fwidth(coverage),0.04);'+#10+
    '  c.a=clamp((coverage-0.30)/edge+0.5,0.0,1.0);'+#10+
    '  if(c.a<0.12)discard;'+#10+
    '  shade=mix(0.40,1.05,atlas.r)*(0.88+0.20*rhParam.w);'+#10+
    '  shade*=mix(0.80,1.0,smoothstep(0.0,2.5,rhParam.y));'+#10+
    ' }'+#10+
    ' rhAlbedo=rhColor*shade;c.rgb=rhAlbedo;'+#10+
    '}'+#10+
    'void PLUG_material_metallic_roughness(inout float m,inout float r) {m=0.0;r=0.67;}'+#10+
    RiderHairLightShader;
end;
function RiderHairLightShader:String;
begin
  Result:=
    // Compact R / TT / TRT lobes. Single-fibre scattering is approximated for
    // a card clump; no claim of full multiple scattering or strand visibility.
    'float rhGaussian(float x,float sigma) {return exp(-0.5*x*x/(sigma*sigma))/(2.5066283*sigma);}'+#10+
    'void PLUG_physical_light_contribution(inout vec3 light,const vec3 L,const vec3 N,const vec3 V) {'+#10+
    ' vec3 T=normalize(rhTangent),H=normalize(L+V+vec3(1e-7));float th=dot(T,H);'+#10+
    ' float wrap=max(dot(N,L)*0.65+0.35,0.0);'+#10+
    ' vec3 cheap=rhAlbedo*(0.20*wrap)+vec3(0.045)*pow(max(1.0-th*th,0.0),18.0);'+#10+
    ' if(rhDetail<0.01){light=cheap;return;}'+#10+
    ' float sl=clamp(dot(T,L),-0.99,0.99),sv=clamp(dot(T,V),-0.99,0.99);'+#10+
    ' vec3 lp=L-T*sl,vp=V-T*sv;'+#10+
    ' float phi=clamp(dot(lp,vp)/max(length(lp)*length(vp),1e-5),-1.0,1.0);'+#10+
    ' float cd=sqrt(max(1.0-0.25*(sl-sv)*(sl-sv),0.08));'+#10+
    ' float fh=sqrt(max(0.5+0.5*phi,0.0))*cd;'+#10+
    ' float F=0.0465+0.9535*pow(1.0-fh,5.0);'+#10+
    ' float longitudinal=sl+sv;'+#10+
    ' float R=rhGaussian(longitudinal+0.07,0.22)*sqrt(max(0.5+0.5*phi,0.0))*0.25;'+#10+
    ' float TT=rhGaussian(longitudinal-0.035,0.31)*exp(-3.65*phi-3.98);'+#10+
    ' float TRT=rhGaussian(longitudinal-0.14,0.43)*exp(9.0*phi-9.50);'+#10+
    ' vec3 absorption=pow(max(rhAlbedo,vec3(0.002)),vec3(0.65/cd));'+#10+
    ' vec3 single=vec3(F*R)+(1.0-F)*(1.0-F)*(absorption*TT+F*absorption*absorption*TRT);'+#10+
    ' vec3 scatter=rhAlbedo*(0.14+0.14*sqrt(max(dot(rhColor,vec3(0.2126,0.7152,0.0722)),0.0)))*wrap;'+#10+
    ' vec3 full=single*1.25+scatter;'+#10+
    ' light=mix(cheap,full,rhDetail);'+#10+
    '}';
end;
end.
