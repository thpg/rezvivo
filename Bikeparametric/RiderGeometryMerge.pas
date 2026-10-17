unit RiderGeometryMerge;
{$mode objfpc}{$H+}
{ Exact concatenation, not simplification: one shared appearance and skin,
  unchanged index order, UV resolution and every deformation attribute. }
interface
uses X3DNodes;
function RiderMergeCompatible(const A,B:TShapeNode):Boolean;
procedure RiderMergeGeometry(const A,B:TShapeNode;const Destination:TShapeNode);
implementation
uses SysUtils,CastleVectors,CastleBoxes,X3DFields;

function SameUv(const A,B:TAbstractTextureCoordinateNode):Boolean;
var I:Integer;
begin
  if(A=nil)or(B=nil)then Exit(A=B);
  if A.ClassType<>B.ClassType then Exit(False);
  if A is TTextureCoordinateNode then Exit(TTextureCoordinateNode(A).Mapping=TTextureCoordinateNode(B).Mapping);
  if not(A is TMultiTextureCoordinateNode)then Exit(False);
  if TMultiTextureCoordinateNode(A).FdTexCoord.Count<>TMultiTextureCoordinateNode(B).FdTexCoord.Count then Exit(False);
  for I:=0 to TMultiTextureCoordinateNode(A).FdTexCoord.Count-1 do
    if not SameUv(TAbstractTextureCoordinateNode(TMultiTextureCoordinateNode(A).FdTexCoord[I]),
      TAbstractTextureCoordinateNode(TMultiTextureCoordinateNode(B).FdTexCoord[I]))then Exit(False);
  Result:=True;
end;
function RiderMergeCompatible(const A,B:TShapeNode):Boolean;
var X,Y:TIndexedTriangleSetNode;I:Integer;P,Q:TFloatVertexAttributeNode;
begin
  Result:=False;
  if(A=nil)or(B=nil)or(A.Appearance=nil)or(A.Appearance<>B.Appearance)or
    not(A.Geometry is TIndexedTriangleSetNode)or not(B.Geometry is TIndexedTriangleSetNode)then Exit;
  X:=TIndexedTriangleSetNode(A.Geometry);Y:=TIndexedTriangleSetNode(B.Geometry);
  if not(X.Coord is TCoordinateNode)or not(Y.Coord is TCoordinateNode)or
    not(X.Normal is TNormalNode)or not(Y.Normal is TNormalNode)or
    (A.Shading<>B.Shading)or(A.Collision<>B.Collision)or
    (X.CCW<>Y.CCW)or(X.Solid<>Y.Solid)or not X.NormalPerVertex or not Y.NormalPerVertex or
    not X.ColorPerVertex or not Y.ColorPerVertex or((X.Tangent=nil)<>(Y.Tangent=nil))or
    (X.Color<>nil)or(Y.Color<>nil)or not SameUv(X.TexCoord,Y.TexCoord)or
    (X.FdAttrib.Count<>Y.FdAttrib.Count)then Exit;
  for I:=0 to X.FdAttrib.Count-1 do begin
    if not(X.FdAttrib[I]is TFloatVertexAttributeNode)or not(Y.FdAttrib[I]is TFloatVertexAttributeNode)then Exit;
    P:=TFloatVertexAttributeNode(X.FdAttrib[I]);Q:=TFloatVertexAttributeNode(Y.FdAttrib[I]);
    if(P.NameField<>Q.NameField)or(P.NumComponents<>Q.NumComponents)then Exit;
  end;
  Result:=(X.FdSkinWeights0.Count=TCoordinateNode(X.Coord).FdPoint.Count)and
    (Y.FdSkinWeights0.Count=TCoordinateNode(Y.Coord).FdPoint.Count)and
    (X.FdSkinJoints0.Count=X.FdSkinWeights0.Count*4)and(Y.FdSkinJoints0.Count=Y.FdSkinWeights0.Count*4);
end;

function MergeUv(const A,B:TAbstractTextureCoordinateNode):TAbstractTextureCoordinateNode;
var I:Integer;T:TTextureCoordinateNode;M:TMultiTextureCoordinateNode;
begin
  Result:=nil;if A=nil then Exit;
  if A is TTextureCoordinateNode then begin
    T:=TTextureCoordinateNode.Create;T.Mapping:=TTextureCoordinateNode(A).Mapping;
    T.FdPoint.Items.Assign(TTextureCoordinateNode(A).FdPoint.Items);
    T.FdPoint.Items.AddRange(TTextureCoordinateNode(B).FdPoint.Items);Result:=T;
  end else begin
    M:=TMultiTextureCoordinateNode.Create;
    for I:=0 to TMultiTextureCoordinateNode(A).FdTexCoord.Count-1 do M.FdTexCoord.Add(
      MergeUv(TAbstractTextureCoordinateNode(TMultiTextureCoordinateNode(A).FdTexCoord[I]),
      TAbstractTextureCoordinateNode(TMultiTextureCoordinateNode(B).FdTexCoord[I])));
    Result:=M;
  end;
end;

procedure RiderMergeGeometry(const A,B:TShapeNode;const Destination:TShapeNode);
var S:array[0..1]of TIndexedTriangleSetNode;D:TIndexedTriangleSetNode;
  I,J,K,N,Offset:Integer;C:TCoordinateNode;Normal:TNormalNode;
  Attr,Source:TFloatVertexAttributeNode;
  Bounds,PartBounds:TBox3D;Position:TVector3;
begin
  if not RiderMergeCompatible(A,B)then raise EArgumentException.Create('Incompatible rider parts');
  S[0]:=TIndexedTriangleSetNode(A.Geometry);S[1]:=TIndexedTriangleSetNode(B.Geometry);
  D:=TIndexedTriangleSetNode.Create;C:=TCoordinateNode.Create;Normal:=TNormalNode.Create;
  D.Coord:=C;D.Normal:=Normal;D.CCW:=S[0].CCW;D.Solid:=S[0].Solid;
  if S[0].Tangent<>nil then D.Tangent:=TTangentNode.Create;
  D.TexCoord:=MergeUv(S[0].TexCoord,S[1].TexCoord);
  for J:=0 to S[0].FdAttrib.Count-1 do begin
    Source:=TFloatVertexAttributeNode(S[0].FdAttrib[J]);Attr:=TFloatVertexAttributeNode.Create;
    Attr.NameField:=Source.NameField;Attr.NumComponents:=Source.NumComponents;D.FdAttrib.Add(Attr);
  end;
  Offset:=0;Bounds:=TBox3D.Empty;
  for I:=0 to 1 do begin
    if I=0 then PartBounds:=A.BBox else PartBounds:=B.BBox;
    Bounds.Include(PartBounds);
    N:=TCoordinateNode(S[I].Coord).FdPoint.Count;
    for J:=0 to N-1 do begin
      if S[I].InternalOriginalCoords<>nil then Position:=S[I].InternalOriginalCoords[J]
      else Position:=TCoordinateNode(S[I].Coord).FdPoint.Items[J];
      C.FdPoint.Items.Add(Position);
      { Preserve authored skinned bounds. A source without explicit bounds
        uses its actual geometry, as it did before concatenation. }
      if PartBounds.IsEmpty then Bounds.Include(Position);
      if S[I].InternalOriginalNormals<>nil then Normal.FdVector.Items.Add(S[I].InternalOriginalNormals[J])
      else Normal.FdVector.Items.Add(TNormalNode(S[I].Normal).FdVector.Items[J]);
      if D.Tangent<>nil then begin
        if S[I].InternalOriginalTangents<>nil then D.Tangent.FdVector.Items.Add(S[I].InternalOriginalTangents[J])
        else D.Tangent.FdVector.Items.Add(S[I].Tangent.FdVector.Items[J]);
      end;
      D.FdSkinWeights0.Items.Add(S[I].FdSkinWeights0.Items[J]);
      for K:=0 to 3 do D.FdSkinJoints0.Items.Add(S[I].FdSkinJoints0.Items[J*4+K]);
    end;
    for J:=0 to S[I].FdIndex.Count-1 do D.FdIndex.Items.Add(S[I].FdIndex.Items[J]+Offset);
    for J:=0 to S[I].FdAttrib.Count-1 do begin
      Source:=TFloatVertexAttributeNode(S[I].FdAttrib[J]);Attr:=TFloatVertexAttributeNode(D.FdAttrib[J]);
      Attr.FdValue.Items.AddRange(Source.FdValue.Items);
    end;
    Inc(Offset,N);
  end;
  Destination.Appearance:=A.Appearance;Destination.Shading:=A.Shading;Destination.Collision:=A.Collision;
  Destination.BBox:=Bounds;
  Destination.Geometry:=D;
end;
end.
