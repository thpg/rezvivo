unit RiderLimbRelief;
{$mode objfpc}{$H+}

{ Anatomical skin relief, in canonical bind metres. This is a height DATA
  texture, not painted light/shadow. Its surface gradient follows the posed
  skin, including forearm twist and body morphs, without another skinning pass.
  RG stores signed residual height baked from the SAME surface as geometry;
  B stores subtle pigment variation. No independent Gaussian muscle layer. }
interface
uses X3DNodes;

function CreateRiderLimbReliefTexture:TImageTextureNode;

const RiderLimbReliefGLSL=
  'uniform sampler2D rsLimbAtlas;uniform vec2 rsLimbRelief;'+#10+
  'float rsLimbPigment=0.0;'+#10+
  'float rsLimbHeight(vec3 p){'+#10+
  ' float arm=step(1.12,p.y),along,angle,mask;vec3 q=vec3(abs(p.x),p.y,p.z);'+#10+
  ' if(arm>0.5){'+#10+
  '  vec3 axisA=normalize(vec3(0.283588,-0.039295,-0.017460)),axisB=normalize(vec3(0.220646,0.0,0.098346));'+#10+
  '  vec3 upA=normalize(vec3(0.0,1.0,0.0)-axisA*axisA.y),upB=vec3(0.0,1.0,0.0);'+#10+
  '  vec3 a=q-vec3(0.165001,1.434600,-0.084599),b=q-vec3(0.448589,1.395305,-0.102059);'+#10+
  // A hard frame switch cuts an oblique plane through the elbow skin and
  // creates a false normal seam. Interpolate the two bind charts smoothly.
  '  float joint=smoothstep(0.415,0.482,q.x);'+#10+
  '  vec2 radial=mix(vec2(dot(a,upA),dot(a,cross(axisA,upA))),vec2(dot(b,upB),dot(b,cross(axisB,upB))),joint);'+#10+
  '  angle=atan(radial.y,radial.x);along=mix(dot(a,axisA),0.28683+dot(b,axisB),joint)/0.52840;'+#10+
  '  mask=rsBand(q.x,0.19,0.25,0.62,0.675)*rsBand(q.y,1.20,1.29,1.51,1.57);'+#10+
  ' }else{'+#10+
  '  float bend=smoothstep(0.40,0.56,q.y);vec2 centre=mix(vec2(0.130,-0.066),vec2(0.114882+0.019175*(q.y-0.524497),-0.022656+0.006138*(q.y-0.524497)),bend);'+#10+
  '  vec2 d=vec2(q.x,q.z)-centre;'+#10+
  '  angle=atan(d.y,d.x);along=(q.y-0.08)/0.94;mask=rsBand(q.y,0.105,0.18,0.76,0.865)*smoothstep(0.025,0.065,q.x);'+#10+
  ' }'+#10+
  // No implicit mip derivative across the cylindrical atan seam. Linear
  // data sampling plus physical bandwidth fades cannot turn this seam into
  // a blurry/dark stripe. The atlas has periodic S and zero-height gutters.
  ' vec2 uv=vec2(angle/6.2831853+0.5,(clamp(along,0.0,1.0)*511.0+0.5+arm*512.0)/1024.0);'+#10+
  ' vec4 data=texture2D(rsLimbAtlas,uv);float h=dot(data.rg,vec2(256.0,1.0))*(0.020/257.0)-0.010;float footprint=max(length(dFdx(p)),length(dFdy(p)));'+#10+
  ' float filter=1.0-smoothstep(0.008,0.025,footprint);rsLimbPigment=(data.b-0.5)*mask;'+#10+
  ' return h*filter*mask*rsLimbRelief.x*(0.85+0.15*rsLimbRelief.y);'+#10+
  '}';

implementation
uses RiderConstructionAtlas;
function CreateRiderLimbReliefTexture:TImageTextureNode;
begin Result:=CreateRiderMasterLimbTexture end;
end.
