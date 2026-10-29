unit RiderSurfaceMotion;
{$mode objfpc}{$H+}
interface
uses X3DNodes,CastleVectors;
const
  RiderSurfaceMotionVS=
    '#define RIDER_SURFACE_MOTION'+#10+
    { Pack horizontal displacement and two normal slopes in ONE attribute.
      No extra attribute slot, texture fetch or CPU mesh walk per frame. }
    'attribute vec4 riderSurfaceDelta;uniform float riderSurfaceAmount;'+#10+
    '#ifndef GL_ES'+#10+'attribute vec3 castle_Normal;'+#10+'#endif'+#10+
    '#ifdef RIDER_SURFACE_NATIVE_SKIN'+#10+
    '' + #10 + '#ifndef GL_ES' + #10 + 'mat4 skinMatrix;' + #10 + '#endif' + #10 + ''+#10+
    '#endif'+#10+
    '#ifdef RIDER_GARMENT_SHAPE'+#10+'void riderGarmentDeform(inout vec3 p,inout vec3 n,mat3 frame);'+#10+'#endif'+#10+
    'void riderSurfaceDeform(inout vec3 p,inout vec3 n,mat3 frame){'+#10+
    '#ifdef RIDER_GARMENT_SHAPE'+#10+
    'riderGarmentDeform(p,n,frame);'+#10+'#endif'+#10+'}'+#10+
    '#ifdef RIDER_SURFACE_RESPIRATION'+#10+
    'vec3 riderSurfaceOffset(){return vec3(riderSurfaceDelta.x,0.0,riderSurfaceDelta.y)*riderSurfaceAmount;}'+#10+
    'vec3 riderSurfaceNormalOffset(){vec3 n=normalize(castle_Normal);'+#10+
    'vec3 t=normalize(cross(n,abs(n.y)<0.9?vec3(0,1,0):vec3(1,0,0)));'+#10+
    'return (t*riderSurfaceDelta.z+cross(n,t)*riderSurfaceDelta.w)*riderSurfaceAmount;}'+#10+
    '#else'+#10+
    'vec3 riderSurfaceOffset(){return riderSurfaceDelta.xyz*riderSurfaceAmount;}'+#10+
    'vec3 riderSurfaceNormalOffset(){return vec3(0.0);}'+#10+'#endif'+#10+
    { CGE calls the native skin plug first. Legacy avatars consume this offset
      through that palette. Shared-body deformation reads the bind attribute
      directly and applies breathing once through its own deformation map. }
    'void PLUG_vertex_object_space_change(inout vec4 p,inout vec3 n){'+#10+
    '#ifdef RIDER_SURFACE_NATIVE_SKIN'+#10+
    'p.xyz+=mat3(skinMatrix)*riderSurfaceOffset();'+#10+
    '#if !defined(CASTLE_SHADOW_DEPTH) || defined(CASTLE_CACHE_DEFORMATION)'+#10+
    'n+=mat3(skinMatrix)*riderSurfaceNormalOffset();'+#10+'#endif'+#10+
    '#ifdef RIDER_GARMENT_SHAPE'+#10+
    'riderGarmentDeform(p.xyz,n,mat3(skinMatrix));'+#10+'#endif'+#10+
    '#endif'+#10+
    '}'+#10;
function AddRiderSurfaceAttribute(Geo:TAbstractComposedGeometryNode):TFloatVertexAttributeNode;
{ Legacy mouth surface uses a full xyz displacement, not respiratory packing. }
procedure AddRiderSurfaceDelta(Attr:TFloatVertexAttributeNode;const Delta:TVector3);
procedure AddRiderSurfaceSample(Attr:TFloatVertexAttributeNode;const P,N:TVector3;
  PositionScale:Single;Enabled:Boolean=True);
procedure RefreshRiderRespiration(Geo:TAbstractComposedGeometryNode;CanonicalScale:Single);
{ Canonical 1.8 m thoracoabdominal excursion, from a relaxed expiration.
  Lower ribs and abdomen move in phase; neither is permanently pulled in.
  Amplitudes are an authored visual fit, not clinical measurements. }
function RiderRespiratoryExpansion(const P:TVector3):TVector3;
function RiderRespiratorySample(const P,N:TVector3;PositionScale:Single):TVector4;
implementation
uses Math;
function Smooth(A,B,V:Single):Single;
begin Result:=EnsureRange((V-A)/(B-A),0,1);Result:=Result*Result*(3-2*Result)end;
function RiderRespiratoryExpansion(const P:TVector3):TVector3;
var Abdomen,LowerRibs,UpperRibs,Trunk,Front,Back:Single;
begin
  Abdomen:=Smooth(0.96,1.055,P.Y)*(1-Smooth(1.12,1.28,P.Y));
  LowerRibs:=Smooth(1.08,1.20,P.Y)*(1-Smooth(1.30,1.43,P.Y));
  UpperRibs:=Smooth(1.23,1.33,P.Y)*(1-Smooth(1.39,1.46,P.Y));
  Trunk:=1-Smooth(0.17,0.235,Abs(P.X));
  Front:=Smooth(-0.025,0.08,P.Z);Back:=1-Smooth(-0.12,-0.035,P.Z);
  Result:=Vector3(P.X*(0.028*Abdomen+0.040*LowerRibs+0.012*UpperRibs),0,
    (0.012*Abdomen+0.008*LowerRibs+0.003*UpperRibs)*Front-
    (0.001*Abdomen+0.002*LowerRibs+0.001*UpperRibs)*Back)*Trunk;
end;
function RiderRespiratorySample(const P,N:TVector3;PositionScale:Single):TVector4;
const E=0.0002;
var Normal,T,B,DT,DB,M,D:TVector3;Along:Single;
begin
  Normal:=N;if Normal.LengthSqr<1e-10 then Normal:=Vector3(0,0,1);
  Normal:=Normal.Normalize;
  if Abs(Normal.Y)<0.9 then T:=Vector3(0,1,0)else T:=Vector3(1,0,0);
  T:=TVector3.CrossProduct(Normal,T).Normalize;B:=TVector3.CrossProduct(Normal,T);
  { Differentiate the actual displacement at author/load time. Store the
    endpoint normal in the rest tangent frame; interpolation of its slopes
    follows the small respiratory excursion without an extra normal effect. }
  DT:=T+(RiderRespiratoryExpansion(P+T*E)-RiderRespiratoryExpansion(P-T*E))*(0.5/E);
  DB:=B+(RiderRespiratoryExpansion(P+B*E)-RiderRespiratoryExpansion(P-B*E))*(0.5/E);
  M:=TVector3.CrossProduct(DT,DB);Along:=Max(0.1,TVector3.DotProduct(M,Normal));
  D:=RiderRespiratoryExpansion(P)*PositionScale;
  Result:=Vector4(D.X,D.Z,TVector3.DotProduct(M,T)/Along,TVector3.DotProduct(M,B)/Along);
end;
function AddRiderSurfaceAttribute(Geo:TAbstractComposedGeometryNode):TFloatVertexAttributeNode;
var I:Integer;
begin
  for I:=0 to Geo.FdAttrib.Count-1 do
    if(Geo.FdAttrib[I]is TFloatVertexAttributeNode)and
      (TFloatVertexAttributeNode(Geo.FdAttrib[I]).NameField='riderSurfaceDelta')then
        Exit(TFloatVertexAttributeNode(Geo.FdAttrib[I]));
  Result:=TFloatVertexAttributeNode.Create;Result.NameField:='riderSurfaceDelta';Result.NumComponents:=4;
  Geo.FdAttrib.Add(Result);
end;
procedure AddRiderSurfaceSample(Attr:TFloatVertexAttributeNode;const P,N:TVector3;
  PositionScale:Single;Enabled:Boolean);
var Sample:TVector4;I:Integer;
begin
  Sample:=Vector4(0,0,0,0);
  if Enabled then Sample:=RiderRespiratorySample(P,N,PositionScale);
  for I:=0 to 3 do Attr.FdValue.Items.Add(Sample.Data[I]);
end;
procedure AddRiderSurfaceDelta(Attr:TFloatVertexAttributeNode;const Delta:TVector3);
begin
  Attr.FdValue.Items.Add(Delta.X);Attr.FdValue.Items.Add(Delta.Y);
  Attr.FdValue.Items.Add(Delta.Z);Attr.FdValue.Items.Add(0);
end;
procedure RefreshRiderRespiration(Geo:TAbstractComposedGeometryNode;CanonicalScale:Single);
var Attr:TFloatVertexAttributeNode;Coord:TCoordinateNode;I:Integer;N:TVector3;
begin
  if not(Geo.Coord is TCoordinateNode)then Exit;
  Coord:=TCoordinateNode(Geo.Coord);Attr:=AddRiderSurfaceAttribute(Geo);
  Attr.NumComponents:=4;Attr.FdValue.Items.Clear;
  for I:=0 to Coord.FdPoint.Count-1 do begin
    N:=Vector3(0,0,1);
    if(Geo.Normal is TNormalNode)and(I<TNormalNode(Geo.Normal).FdVector.Count)then
      N:=TNormalNode(Geo.Normal).FdVector.Items[I];
    AddRiderSurfaceSample(Attr,Coord.FdPoint.Items[I]*CanonicalScale,N,1/CanonicalScale);
  end;
  Attr.FdValue.Changed;
end;
end.
