unit GameFarFieldProbe;

{$mode objfpc}{$H+}

{ Explicit MCP-only, reversible render experiment. No per-frame work, no cache
  writes, no streaming/physics changes. Retained nodes keep restore safe even
  when a tile is evicted. Index filtering happens outside the measured window. }
interface

uses fpjson, CastleVectors, Osm3dStreamingMap;

procedure RunFarFieldProbe(Map: TOsm3dStreamingMap; const Camera: TVector3;
  Params, Output: TJSONObject);
procedure ClearFarFieldProbe;

implementation

uses SysUtils, Math, X3DNodes, Osm3dStudioSettings;

type
  TIndexArray = array of LongInt;
  TRangeArray = array of Single;
  TGeometrySave = record
    Node: TIndexedFaceSetNode;
    Shape: TShapeNode;
    RenderNode: TIndexedFaceSetNode;
    Indices: TIndexArray;
    Kind: String;
    Modified: Boolean;
  end;
  TLodSave = record
    Node: TLODNode;
    Ranges: TRangeArray;
    Modified: Boolean;
  end;

var
  Geometries: array of TGeometrySave;
  Lods: array of TLodSave;
  SettingsSaved: Boolean = False;
  SavedTreeFar, SavedShrubFar: Single;

procedure Restore;
var I: Integer;
begin
  for I := 0 to High(Geometries) do
    if Geometries[I].Modified then
    begin
      { GPU contact bins retain the original Geometry and triangle IDs.
        Never compact their coordIndex in place, even outside the radius. }
      Geometries[I].Shape.Geometry := Geometries[I].Node;
      Geometries[I].RenderNode.KeepExistingEnd;
      Geometries[I].RenderNode.FreeIfUnused;
      Geometries[I].RenderNode := nil;
      Geometries[I].Modified := False;
    end;
  for I := 0 to High(Lods) do
    if Lods[I].Modified then
    begin
      Lods[I].Node.FdRange.Send(Lods[I].Ranges);
      Lods[I].Modified := False;
    end;
  if SettingsSaved then
  begin
    GlobalLODConfig.TreesFarMeters := SavedTreeFar;
    GlobalLODConfig.ShrubsFarMeters := SavedShrubFar;
  end;
end;

procedure ClearFarFieldProbe;
var I: Integer;
begin
  Restore;
  for I := 0 to High(Geometries) do
  begin
    Geometries[I].Shape.KeepExistingEnd;
    Geometries[I].Shape.FreeIfUnused;
    Geometries[I].Node.KeepExistingEnd;
    Geometries[I].Node.FreeIfUnused;
  end;
  for I := 0 to High(Lods) do
  begin
    Lods[I].Node.KeepExistingEnd;
    Lods[I].Node.FreeIfUnused;
  end;
  SetLength(Geometries, 0);
  SetLength(Lods, 0);
  SettingsSaved := False;
end;

function SaveGeometry(AShape: TShapeNode; Geo: TIndexedFaceSetNode; const AKind: String): Integer;
var I: Integer;
begin
  for I := 0 to High(Geometries) do
    if Geometries[I].Node = Geo then Exit(I);
  Result := Length(Geometries);
  SetLength(Geometries, Result + 1);
  with Geometries[Result] do
  begin
    Node := Geo;
    Node.KeepExistingBegin;
    Shape := AShape;
    Shape.KeepExistingBegin;
    RenderNode := nil;
    SetLength(Indices, Geo.FdCoordIndex.Count);
    for I := 0 to High(Indices) do Indices[I] := Geo.FdCoordIndex.Items[I];
    Kind := AKind;
    Modified := False;
  end;
end;

function SaveLod(Node: TLODNode): Integer;
var I: Integer;
begin
  for I := 0 to High(Lods) do if Lods[I].Node = Node then Exit(I);
  Result := Length(Lods);
  SetLength(Lods, Result + 1);
  Lods[Result].Node := Node;
  Node.KeepExistingBegin;
  SetLength(Lods[Result].Ranges, Node.FdRange.Count);
  for I := 0 to High(Lods[Result].Ranges) do
    Lods[Result].Ranges[I] := Node.FdRange.Items[I];
end;

procedure RunFarFieldProbe(Map: TOsm3dStreamingMap; const Camera: TVector3;
  Params, Output: TJSONObject);
var
  Mode, Kind, Name: String;
  Radius, RadiusSq, PbrM, FullM: Single;
  B: TCacheBatch;
  T: TCacheTile;
  Root: TX3DRootNode;
  Lod: TLODNode;
  Group: TAbstractGroupingNode;
  Shape: TShapeNode;
  Placement: TTransformNode;
  Geo: TIndexedFaceSetNode;
  Coord: TCoordinateNode;
  I, J, K, S, Start, N, V, OutN, Count, Li: Integer;
  MinX, MaxX, MinZ, MaxZ, Dx, Dz: Single;
  P: TVector3;
  Cut: TIndexArray;
  Seen: array of TIndexedFaceSetNode;
  Shapes: array of TShapeNode;
  Offsets: array of TVector3;
  Duplicate, Selected: Boolean;
  TotalFaces, KeptFaces, BldFaces, BldKept, GroundFaces, GroundKept: Int64;
  Rows: TJSONArray;
  Row: TJSONObject;
begin
  if Map = nil then raise Exception.Create('Active OSM map required');
  Mode := Params.Get('mode', 'inspect');
  if (Mode <> 'inspect') and (Mode <> 'original') and (Mode <> 'buildings') and
     (Mode <> 'static') and (Mode <> 'ground') and (Mode <> 'trees') and (Mode <> 'lod') then
    raise Exception.Create('Expected inspect|original|buildings|ground|static|trees|lod');
  Radius := Params.Get('distance_m', 1000.0);
  PbrM := Params.Get('pbr_m', 2500.0);
  FullM := Params.Get('full_m', 6000.0);
  if (Radius < 100) or (Radius > 50000) or (PbrM < 0) or (FullM < PbrM) then
    raise Exception.Create('Invalid diagnostic distances');
  if not SettingsSaved then
  begin
    SavedTreeFar := GlobalLODConfig.TreesFarMeters;
    SavedShrubFar := GlobalLODConfig.ShrubsFarMeters;
    SettingsSaved := True;
  end;
  if Mode <> 'inspect' then Restore;
  if (Mode = 'trees') or Params.Get('cut_trees', False) then
  begin
    GlobalLODConfig.TreesFarMeters := Radius;
    GlobalLODConfig.ShrubsFarMeters := Radius;
  end;
  RadiusSq := Sqr(Radius);
  TotalFaces := 0; KeptFaces := 0; BldFaces := 0; BldKept := 0;
  GroundFaces := 0; GroundKept := 0;
  SetLength(Seen, 0);
  Rows := TJSONArray.Create; Output.Add('tiles', Rows);
  for B in Map.RootBlocks do for T in B.Tiles do
  begin
    if (T.Scene = nil) or not T.Scene.MountLoaded or
       (T.Scene.RootNode = nil) or not T.Active then Continue;
    Root := T.Scene.RootNode;
    Lod := nil;
    for I := 0 to Root.FdChildren.Count - 1 do
      if Root.FdChildren[I] is TLODNode then Lod := TLODNode(Root.FdChildren[I]);
    if (Lod = nil) or (Lod.FdChildren.Count < 3) then Continue;
    Li := SaveLod(Lod);
    if Mode = 'lod' then
    begin
      Lod.FdRange.Send([PbrM, FullM]);
      Lods[Li].Modified := True;
    end;
    P := Lod.FdCenter.Value;
    Row := TJSONObject.Create(['tile', T.Tile.ToString,
      'center_x', T.CenterX, 'center_z', T.CenterZ,
      'center_distance_m', (Camera-P).Length,
      'pbr_m', Lod.FdRange.Items[0], 'full_m', Lod.FdRange.Items[1]]);
    Rows.Add(Row);
    if not (Lod.FdChildren[0] is TAbstractGroupingNode) then Continue;
    Group := TAbstractGroupingNode(Lod.FdChildren[0]);
    SetLength(Shapes, 0); SetLength(Offsets, 0);
    for I := 0 to Group.FdChildren.Count - 1 do
    begin
      if Group.FdChildren[I] is TShapeNode then
      begin
        N := Length(Shapes); SetLength(Shapes,N+1); SetLength(Offsets,N+1);
        Shapes[N] := TShapeNode(Group.FdChildren[I]); Offsets[N] := Vector3(0,0,0);
      end
      else if Group.FdChildren[I] is TTransformNode then
      begin
        { Ground uses tile-local coordinates plus GroundPlacement. Other
          composites are world-space. Never treat a local vertex as world-space. }
        Placement := TTransformNode(Group.FdChildren[I]);
        if (Abs(Placement.Rotation.W)>1e-6) or
           ((Placement.Scale-Vector3(1,1,1)).Length>1e-6) then Continue;
        for J:=0 to Placement.FdChildren.Count-1 do
          if Placement.FdChildren[J] is TShapeNode then
          begin
            N:=Length(Shapes); SetLength(Shapes,N+1); SetLength(Offsets,N+1);
            Shapes[N]:=TShapeNode(Placement.FdChildren[J]); Offsets[N]:=Placement.Translation;
          end;
      end;
    end;
    for I:=0 to High(Shapes) do
    begin
      Shape := Shapes[I];
      if not (Shape.Geometry is TIndexedFaceSetNode) then Continue;
      Geo := TIndexedFaceSetNode(Shape.Geometry);
      if not (Geo.Coord is TCoordinateNode) then Continue;
      { Only world-space tile composites. POI child transforms and vegetation
        use independent renderers and are deliberately not altered here. }
      Kind := '';
      for J := 0 to Geo.FdAttrib.Count - 1 do
        if Geo.FdAttrib[J] is TFloatVertexAttributeNode then
        begin
          Name := TFloatVertexAttributeNode(Geo.FdAttrib[J]).NameField;
          if Name = 'bldUV' then Kind := 'buildings';
          if Name = 'groundUV' then Kind := 'ground';
          if Name = 'fncUV' then Kind := 'fences';
          if Name = 'pltUV' then Kind := 'plates';
        end;
      if Kind = '' then Continue;
      Duplicate := False;
      for J := 0 to High(Seen) do if Seen[J] = Geo then Duplicate := True;
      if Duplicate then Continue;
      N := Length(Seen); SetLength(Seen, N+1); Seen[N] := Geo;
      S := SaveGeometry(Shape, Geo, Kind);
      Coord := TCoordinateNode(Geo.Coord);
      Selected := (Mode = 'static') or ((Mode = 'buildings') and (Kind = 'buildings')) or
        ((Mode = 'ground') and (Kind = 'ground'));
      SetLength(Cut, Length(Geometries[S].Indices));
      Start := 0; OutN := 0;
      for J := 0 to High(Geometries[S].Indices) do
        if Geometries[S].Indices[J] = -1 then
        begin
          Count := J - Start;
          if Count >= 3 then
          begin
            MinX := 1e30; MinZ := 1e30; MaxX := -1e30; MaxZ := -1e30;
            for K := Start to J-1 do
            begin
              V := Geometries[S].Indices[K];
              if (V < 0) or (V >= Coord.FdPoint.Count) then
                raise Exception.Create('Invalid composite vertex index');
              P := Coord.FdPoint.Items[V] + Offsets[I];
              MinX := Min(MinX, P.X); MaxX := Max(MaxX, P.X);
              MinZ := Min(MinZ, P.Z); MaxZ := Max(MaxZ, P.Z);
            end;
            Dx := Max(Max(MinX-Camera.X, Camera.X-MaxX), 0);
            Dz := Max(Max(MinZ-Camera.Z, Camera.Z-MaxZ), 0);
            Inc(TotalFaces, Count-2);
            if Kind = 'buildings' then Inc(BldFaces, Count-2);
            if Kind = 'ground' then Inc(GroundFaces, Count-2);
            if not Selected or (Sqr(Dx)+Sqr(Dz) <= RadiusSq) then
            begin
              for K := Start to J do begin Cut[OutN] := Geometries[S].Indices[K]; Inc(OutN); end;
              Inc(KeptFaces, Count-2);
              if Kind = 'buildings' then Inc(BldKept, Count-2);
              if Kind = 'ground' then Inc(GroundKept, Count-2);
            end;
          end;
          Start := J+1;
        end;
      if Selected then
      begin
        SetLength(Cut, OutN);
        { Separate draw-only geometry. DeepCopy also keeps future additions
          to composite vertex fields intact. The diagnostic memory overhead
          is deliberate; this is not a memory-saving implementation. }
        Geometries[S].RenderNode := TIndexedFaceSetNode(Geo.DeepCopy);
        Geometries[S].RenderNode.KeepExistingBegin;
        Geometries[S].RenderNode.SetCoordIndex(Cut);
        Geometries[S].Modified := True;
        Shape.Geometry := Geometries[S].RenderNode;
      end;
    end;
  end;
  Output.Add('mode', Mode); Output.Add('distance_m', Radius);
  Output.Add('camera', TJSONArray.Create([Camera.X, Camera.Y, Camera.Z]));
  Output.Add('composite_triangles', TJSONInt64Number.Create(TotalFaces));
  Output.Add('kept_triangles', TJSONInt64Number.Create(KeptFaces));
  Output.Add('building_triangles', TJSONInt64Number.Create(BldFaces));
  Output.Add('kept_building_triangles', TJSONInt64Number.Create(BldKept));
  Output.Add('ground_triangles', TJSONInt64Number.Create(GroundFaces));
  Output.Add('kept_ground_triangles', TJSONInt64Number.Create(GroundKept));
  Output.Add('tree_far_m', GlobalLODConfig.TreesFarMeters);
  Output.Add('reference', 'Draw-only geometry copy; original contact triangle IDs untouched; XZ face bounds snapshot');
end;

end.
