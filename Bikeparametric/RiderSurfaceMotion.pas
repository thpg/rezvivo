unit RiderSurfaceMotion;
{$mode objfpc}{$H+}
interface
uses X3DNodes,CastleVectors;
const
  RiderSurfaceMotionVS=
    '#define RIDER_SURFACE_MOTION'+#10+
    'attribute vec3 riderSurfaceDelta;uniform float riderSurfaceAmount;'+#10+
    '#ifdef RIDER_SURFACE_NATIVE_SKIN'+#10+
    'mat4 skinMatrix;'+#10+
    '#endif'+#10+
    'vec3 riderSurfaceOffset(){return riderSurfaceDelta*riderSurfaceAmount;}'+#10+
    { CGE calls the native skin plug first. Legacy avatars consume this offset
      through that palette. Shared-body deformation reads the bind attribute
      directly and applies breathing once through its own deformation map. }
    'void PLUG_vertex_object_space_change(inout vec4 p,inout vec3 n){'+#10+
    '#ifdef RIDER_SURFACE_NATIVE_SKIN'+#10+
    'p.xyz+=mat3(skinMatrix)*riderSurfaceOffset();'+#10+
    '#endif'+#10+
    '}'+#10;
function AddRiderSurfaceAttribute(Geo:TAbstractComposedGeometryNode):TFloatVertexAttributeNode;
procedure AddRiderSurfaceDelta(Attr:TFloatVertexAttributeNode;const Delta:TVector3);
{ Canonical 1.8 m bind-space chest expansion, shared by cloth and its logos. }
function RiderChestExpansion(const P:TVector3):TVector3;
implementation
uses Math;
function RiderChestExpansion(const P:TVector3):TVector3;
var Weight:Single;
begin
  Weight:=EnsureRange((P.Y-1.14)/0.12,0,1)*(1-EnsureRange((P.Y-1.37)/0.09,0,1));
  Weight:=Weight*(1-EnsureRange((Abs(P.X)-0.11)/0.085,0,1));
  { Rib expansion also reaches the flanks and back panel. One shared field
    keeps the jersey, trim and overlaid logos attached throughout breathing. }
  Result:=Vector3(P.X*0.014,0,
    0.0024*EnsureRange((P.Z+0.06)/0.13,0,1)-
    0.0009*EnsureRange((-P.Z-0.055)/0.07,0,1))*Weight;
end;
function AddRiderSurfaceAttribute(Geo:TAbstractComposedGeometryNode):TFloatVertexAttributeNode;
var I:Integer;
begin
  for I:=0 to Geo.FdAttrib.Count-1 do
    if(Geo.FdAttrib[I]is TFloatVertexAttributeNode)and
      (TFloatVertexAttributeNode(Geo.FdAttrib[I]).NameField='riderSurfaceDelta')then
        Exit(TFloatVertexAttributeNode(Geo.FdAttrib[I]));
  Result:=TFloatVertexAttributeNode.Create;Result.NameField:='riderSurfaceDelta';Result.NumComponents:=3;
  Geo.FdAttrib.Add(Result);
end;
procedure AddRiderSurfaceDelta(Attr:TFloatVertexAttributeNode;const Delta:TVector3);
begin
  Attr.FdValue.Items.Add(Delta.X);Attr.FdValue.Items.Add(Delta.Y);Attr.FdValue.Items.Add(Delta.Z);
end;
end.
