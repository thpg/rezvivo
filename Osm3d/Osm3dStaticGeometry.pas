unit Osm3dStaticGeometry;

{$mode objfpc}{$H+}

interface

uses CastleVectors, X3DFields, X3DNodes;

{ Populate fields of NEW, unpublished nodes without event dispatch or the
  geometric growth used by SetValue/Send. Never use on a mounted scene. }
procedure AssignStaticField(Field: TMFVec3f; const Values: array of TVector3); overload;
procedure AssignStaticField(Field: TMFVec2f; const Values: array of TVector2); overload;
procedure AssignStaticField(Field: TMFFloat; const Values: array of Single); overload;
procedure AssignStaticField(Field: TMFInt32; const Values: array of LongInt); overload;

{ Call on a completed, private tile graph before Scene.Load publishes it.
  Material selection must already be final: lit geometry needs CGE normals. }
procedure CompactTileGeometry(Root: TX3DNode);

implementation

procedure AssignStaticField(Field: TMFVec3f; const Values: array of TVector3);
begin
  Field.Items.Capacity := Length(Values);
  Field.Items.Count := Length(Values);
  if Length(Values) <> 0 then Move(Values[0], Field.Items.L^, Length(Values)*SizeOf(TVector3));
end;

procedure AssignStaticField(Field: TMFVec2f; const Values: array of TVector2);
begin
  Field.Items.Capacity := Length(Values);
  Field.Items.Count := Length(Values);
  if Length(Values) <> 0 then Move(Values[0], Field.Items.L^, Length(Values)*SizeOf(TVector2));
end;

procedure AssignStaticField(Field: TMFFloat; const Values: array of Single);
begin
  Field.Items.Capacity := Length(Values);
  Field.Items.Count := Length(Values);
  if Length(Values) <> 0 then Move(Values[0], Field.Items.L^, Length(Values)*SizeOf(Single));
end;

procedure AssignStaticField(Field: TMFInt32; const Values: array of LongInt);
begin
  Field.Items.Capacity := Length(Values);
  Field.Items.Count := Length(Values);
  if Length(Values) <> 0 then Move(Values[0], Field.Items.L^, Length(Values)*SizeOf(LongInt));
end;

type
  TGeometryCompactor = class
    procedure Visit(Node: TX3DNode);
  end;

procedure TGeometryCompactor.Visit(Node: TX3DNode);
var
  Shape: TShapeNode;
  Geo: TIndexedFaceSetNode;
  Attr: TFloatVertexAttributeNode;
  I: Integer;
  CustomUV: Boolean;
begin
  if Node is TShapeNode then
  begin
    Shape := TShapeNode(Node);
    if (Shape.Geometry is TIndexedFaceSetNode) and
       (Shape.Appearance is TAppearanceNode) and
       (TAppearanceNode(Shape.Appearance).Material is TUnlitMaterialNode) then
    begin
      Geo := TIndexedFaceSetNode(Shape.Geometry);
      CustomUV := False;
      for I := 0 to Geo.FdAttrib.Count - 1 do
        if Geo.FdAttrib[I] is TFloatVertexAttributeNode then
        begin
          Attr := TFloatVertexAttributeNode(Geo.FdAttrib[I]);
          CustomUV := CustomUV or (Attr.NameField = 'groundUV') or
            (Attr.NameField = 'bldUV') or (Attr.NameField = 'fncUV') or
            (Attr.NameField = 'pltUV');
        end;
      { Keep standard normals even on unlit shapes: CGE otherwise generates
        face normals and expands indexed geometry into a triangle soup.
        Only the unused standard UV stream may be removed here. }
      if CustomUV then Geo.TexCoord := nil;
    end;
  end;

  if Node is TCoordinateNode then
    with TCoordinateNode(Node).FdPoint.Items do Capacity := Count
  else if Node is TNormalNode then
    with TNormalNode(Node).FdVector.Items do Capacity := Count
  else if Node is TTextureCoordinateNode then
    with TTextureCoordinateNode(Node).FdPoint.Items do Capacity := Count
  else if Node is TFloatVertexAttributeNode then
    with TFloatVertexAttributeNode(Node).FdValue.Items do Capacity := Count
  else if Node is TIndexedFaceSetNode then
    with TIndexedFaceSetNode(Node) do
    begin
      FdCoordIndex.Items.Capacity := FdCoordIndex.Count;
      FdNormalIndex.Items.Capacity := FdNormalIndex.Count;
      FdTexCoordIndex.Items.Capacity := FdTexCoordIndex.Count;
      FdColorIndex.Items.Capacity := FdColorIndex.Count;
    end;
end;

procedure CompactTileGeometry(Root: TX3DNode);
var C: TGeometryCompactor;
begin
  if Root = nil then Exit;
  C := TGeometryCompactor.Create;
  try
    { Do not visit shared appearances or LOD aliases. The caller owns this
      newly built shape and its geometry; all material choices are final. }
    C.Visit(Root);
    if (Root is TShapeNode) and (TShapeNode(Root).Geometry <> nil) then
      TShapeNode(Root).Geometry.EnumerateNodes(@C.Visit, False);
  finally C.Free end;
end;

end.
