unit Osm3dRtxRigidGroups;
{$mode objfpc}{$H+}
{ Graph-only articulation classification; no GL or renderer state. }
interface
uses CastleVectors,CastleTransform,X3DNodes;
function RigidBikeGroup(const Shape,SceneRoot:TX3DNode;out Group:TX3DNode;
  out Relative,GroupMatrix:TMatrix4):Boolean;
implementation
{ Classify only the procedural bicycle's explicit articulation roots. A name
  match elsewhere, a multiply-parented node or an unknown graph falls back to
  the ordinary deforming actor. Static translations below a joint are baked
  once; steering, wheel spin and pedal pitch remain in the TLAS transform. }
function RigidBikeGroup(const Shape,SceneRoot:TX3DNode;out Group:TX3DNode;
  out Relative,GroupMatrix:TMatrix4):Boolean;
var Chain:array[0..63]of TX3DNode;N,I,G:Integer;Node:TX3DNode;Bike:Boolean;
  State:TTransformation;Name:string;
begin
  Result:=False;Group:=nil;N:=0;G:=-1;Bike:=False;Node:=Shape;
  while(Node<>nil)and(N<Length(Chain))do begin
    Chain[N]:=Node;Name:=Node.X3DName;
    if Name='BikeFrame'then Bike:=True;
    if(G<0)and((Name='BikeFrame')or(Name='SteerRot')or(Name='RearWheelRot')or
      (Name='FrontWheelRot')or(Name='CranksRot')or(Name='PedalRightFoot')or
      (Name='PedalLeftFoot'))then G:=N;
    Inc(N);if Node=SceneRoot then Break;
    if Node.ParentFieldsCount<>1 then Exit;
    Node:=Node.ParentFieldsNode[0];
  end;
  if not Bike or(G<0)or(Node<>SceneRoot)then Exit;
  State:=IdentityTransformation;
  for I:=G-1 downto 0 do if Chain[I].TransformFunctionality<>nil then
    Chain[I].TransformFunctionality.ApplyTransform(State);
  Relative:=State.Transform;State:=IdentityTransformation;
  for I:=N-1 downto G do if Chain[I].TransformFunctionality<>nil then
    Chain[I].TransformFunctionality.ApplyTransform(State);
  GroupMatrix:=State.Transform;Group:=Chain[G];Result:=True;
end;
end.
