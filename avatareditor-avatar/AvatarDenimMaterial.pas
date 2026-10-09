unit AvatarDenimMaterial;
{$mode objfpc}{$H+}
interface
uses X3DNodes,TripoRig;
procedure ApplyAvatarDenim(Shape:TShapeNode;Rig:TTripoRig;Scale:Single;Deform:Boolean=True);
implementation
uses SysUtils,CastleVectors,X3DFields,CastleRenderOptions,RiderShaderSharing;
const
  DenimFoldGLSL=
    'float adFold(vec3 p,float bend,float hip){'+#10+
    ' float back=1.0-smoothstep(-.055,.010,p.z),y=p.y-.525;'+#10+
    ' float knee=exp(-y*y/0.0032)*back;'+#10+
    ' float phase=y*(72.0+12.0*bend)+8.0*abs(p.x);'+#10+
    ' float h=.0045*bend*knee*(sin(phase)+.3*sin(phase*1.61+.7));'+#10+
    ' float front=smoothstep(-.018,.045,p.z),upper=exp(-pow((p.y-.817)/.085,2.0));'+#10+
    ' h+=.0032*hip*front*upper*sin((p.y+abs(p.x)*.27)*78.0);'+#10+
    ' return h*smoothstep(.025,.065,abs(p.x));}';

  DenimFS=
    'varying vec3 adRest;'+#10+
    'float adSeam=0.0,adStitch=0.0,adWear=0.0;'+#10+
    'float adLine(float d,float w){float aa=max(fwidth(d),.00025);return 1.0-smoothstep(w-aa,w+aa,abs(d));}'+#10+
    'float adSegment(vec2 p,vec2 a,vec2 b){vec2 v=b-a;return length(p-a-v*clamp(dot(p-a,v)/dot(v,v),0.0,1.0));}'+#10+
    'void PLUG_fragment_eye_space(const vec4 p,inout vec3 n){'+#10+
    ' vec3 r=adRest;float x=abs(r.x),y=r.y;vec2 q=vec2(x,y);'+#10+
    ' float front=smoothstep(-.02,.045,r.z),back=1.0-smoothstep(-.085,-.025,r.z);'+#10+
    ' float waist=adLine(y-.967,.0015);'+#10+
    ' float fly=min(adSegment(vec2(r.x,y),vec2(.020,.984),vec2(.020,.904)),adSegment(vec2(r.x,y),vec2(.020,.904),vec2(.006,.880)));'+#10+
    ' float pocket=adSegment(q,vec2(.073,.984),vec2(.171,.925));'+#10+
    ' float coin=min(adSegment(q,vec2(.097,.966),vec2(.132,.945)),adSegment(q,vec2(.097,.966),vec2(.097,.941)));'+#10+
    ' coin=mix(1.0,coin,step(0.0,r.x));'+#10+
    ' float bd=min(adSegment(q,vec2(.049,.956),vec2(.156,.946)),adSegment(q,vec2(.049,.956),vec2(.049,.847)));'+#10+
    ' bd=min(bd,adSegment(q,vec2(.156,.946),vec2(.156,.837)));'+#10+
    ' bd=min(bd,adSegment(q,vec2(.049,.847),vec2(.1025,.819)));'+#10+
    ' bd=min(bd,adSegment(q,vec2(.1025,.819),vec2(.156,.837)));'+#10+
    ' float yoke=adSegment(q,vec2(0,.961),vec2(.187,.992));'+#10+
    ' float side=abs(r.z+.036);float sideMask=smoothstep(.160,.183,x)*(1.0-smoothstep(.94,1.01,y));'+#10+
    ' float seams=max(waist,max(front*adLine(min(fly,min(pocket,coin)),.0018),back*adLine(min(bd,yoke),.0018)));'+#10+
    ' seams=max(seams,adLine(side,.0018)*sideMask);'+#10+
    ' seams=max(seams,adLine(y-.079,.0015));adSeam=seams;'+#10+
    ' float stitchDist=min(abs(bd-.0045),abs(bd-.0075));'+#10+
    ' float stitches=max(back*adLine(stitchDist,.00055),front*adLine(abs(min(pocket,fly)-.0045),.00055));'+#10+
    ' stitches=max(stitches,.75*adLine(abs(y-.967)-.004,.00055));'+#10+
    ' float threadPhase=(x+y)*235.0,foot=fwidth(threadPhase);'+#10+
    ' float dash=.63+.37*cos(6.2831853*threadPhase)*exp2(-8.0*foot*foot);adStitch=stitches*dash;'+#10+
    ' float faded=exp(-pow((y-.56)/.11,2.0))*front*.16;'+#10+
    ' faded+=exp(-pow((y-.74)/.18,2.0))*front*.09;'+#10+
    ' float warp=sin(r.x*271.0+sin(y*27.0)*.7),slub=sin(r.x*613.0+y*3.0);'+#10+
    ' float fadeFilter=exp2(-8.0*pow(fwidth(r.x*98.0),2.0));'+#10+
    ' adWear=faded+.020*warp*fadeFilter+.014*slub*fadeFilter;'+#10+
    ' float h=.0007*seams+.00025*stitches;'+#10+
    ' vec3 dx=dFdx(p.xyz),dy=dFdy(p.xyz),N=normalize(n),a=cross(dy,N),b=cross(N,dx);float det=dot(dx,a);'+#10+
    ' if(det*det>1e-12*dot(dx,dx)*dot(dy,dy)){vec3 grad=(a*dFdx(h)+b*dFdy(h))/det;grad*=min(1.0,.45/max(length(grad),1e-8));n=normalize(N-grad);}'+#10+
    '}'+#10+
    'void PLUG_main_texture_apply(inout vec4 c,const vec3 n){'+#10+
    ' c.rgb*=1.0+adWear+.09*adSeam;'+#10+
    ' c.rgb=mix(c.rgb,c.rgb*.65+vec3(.19,.125,.056),adStitch*.72);'+#10+
    '}';

procedure ApplyAvatarDenim(Shape:TShapeNode;Rig:TTripoRig;Scale:Single;Deform:Boolean);
var App:TAppearanceNode;Geo:TAbstractComposedGeometryNode;Coord:TCoordinateNode;
  Attr:TFloatVertexAttributeNode;Effect:TEffectNode;V,F:TEffectPartNode;
  I,LH,LK,RH,RK,Hip:Integer;P:TVector3;VS:string;
begin
  if(Rig=nil)or not(Shape.Appearance is TAppearanceNode)or
    not(Shape.Geometry is TAbstractComposedGeometryNode)then Exit;
  Geo:=TAbstractComposedGeometryNode(Shape.Geometry);
  if not(Geo.Coord is TCoordinateNode)then Exit;
  App:=TAppearanceNode(Shape.Appearance);Coord:=TCoordinateNode(Geo.Coord);
  Attr:=TFloatVertexAttributeNode.Create;Attr.NameField:='avatarDenimRest';Attr.NumComponents:=3;
  for I:=0 to Coord.FdPoint.Count-1 do begin
    P:=Coord.FdPoint.Items[I]/Scale;
    Attr.FdValue.Items.Add(P.X);Attr.FdValue.Items.Add(P.Y);Attr.FdValue.Items.Add(P.Z);
  end;
  Geo.FdAttrib.Add(Attr);
  for I:=0 to App.FdEffects.Count-1 do if App.FdEffects[I].X3DName='AvatarDenim'then Exit;
  LH:=Rig.JointIndexByName('L_Thigh');LK:=Rig.JointIndexByName('L_Calf');
  RH:=Rig.JointIndexByName('R_Thigh');RK:=Rig.JointIndexByName('R_Calf');Hip:=Rig.JointIndexByName('Pelvis');
  if(LH<0)or(LK<0)or(RH<0)or(RK<0)or(Hip<0)then Exit;
  VS:=DenimFoldGLSL+#10+
    'attribute vec3 avatarDenimRest;varying vec3 adRest;mat4 bodyJoint(int j);mat4 skinMatrix;uniform float adScale;'+#10+
    'void PLUG_vertex_object_space(inout vec4 p,inout vec3 n){'+#10+
    ' int th='+IntToStr(RH)+',ca='+IntToStr(RK)+';if(avatarDenimRest.x>0.0){th='+IntToStr(LH)+';ca='+IntToStr(LK)+';}'+#10+
    ' vec3 a=normalize(mat3(bodyJoint(th))*vec3(0,1,0)),b=normalize(mat3(bodyJoint(ca))*vec3(0,1,0));'+#10+
    ' float bend=clamp(1.0-dot(a,b),0.0,1.7);'+#10+
    ' float hip=clamp(1.0-dot(a,normalize(mat3(bodyJoint('+IntToStr(Hip)+'))*vec3(0,1,0))),0.0,1.5);'+#10+
    ' vec3 r=avatarDenimRest;float e=.001,h=adFold(r,bend,hip);vec3 grad;'+#10+
    ' grad.x=(adFold(r+vec3(e,0,0),bend,hip)-adFold(r-vec3(e,0,0),bend,hip))/(2.0*e);'+#10+
    ' grad.y=(adFold(r+vec3(0,e,0),bend,hip)-adFold(r-vec3(0,e,0),bend,hip))/(2.0*e);'+#10+
    ' grad.z=(adFold(r+vec3(0,0,e),bend,hip)-adFold(r-vec3(0,0,e),bend,hip))/(2.0*e);'+#10+
    ' grad=mat3(skinMatrix)*grad;p.xyz+=n*h*adScale;n=normalize(n-grad+n*dot(grad,n));'+#10+'}'+#10+
    { Only immutable pattern coordinates are read in the colour pass. Bone
      queries belong to the cached deformation pass: its temporary GPU IK
      matrices do not exist when rendering already skinned VBOs. }
    'void PLUG_vertex_eye_space(const vec4 p,const vec3 n){adRest=avatarDenimRest;}';
  if not Deform then VS:='attribute vec3 avatarDenimRest;varying vec3 adRest;'+#10+
    'void PLUG_vertex_eye_space(const vec4 p,const vec3 n){adRest=avatarDenimRest;}';
  Effect:=TEffectNode.Create('AvatarDenim');Effect.Language:=slGLSL;Effect.UniformMissing:=umIgnore;
  Effect.InternalCacheVertexAnimation:=Deform;
  Effect.AddCustomField(TSFFloat.Create(Effect,True,'adScale',Scale));
  V:=TEffectPartNode.Create;V.ShaderType:=stVertex;V.Contents:=VS;
  F:=TEffectPartNode.Create;F.ShaderType:=stFragment;F.Contents:=DenimFS;
  Effect.SetParts([V,F]);ShareRiderEffect(Effect);App.FdEffects.Add(Effect);
end;
end.
