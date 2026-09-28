unit Osm3dWaterProfile;

{$mode objfpc}{$H+}

interface

uses Math, SysUtils, CastleVectors, Osm3dGeoMath, Osm3dOsmData,
  Osm3dTileX3D;

{ Width, not area or river length, controls the ocean spectrum scale.
  1 km of open water reaches the reference sea; narrow water keeps ripples. }
function WaterScaleForWidth(Width: Double; IsSea: Boolean): Single;
function TileHasMarineWater(Model: TTileModel): Boolean;
procedure BakeWaterScales(Dataset: TOSMDataset; const Origin: TLatLon;
  ScaleLat: Double; const Models: array of TTileModel);

implementation

uses Osm3dGeomSurface, Osm3dGeomUtils, Osm3dGeomMesh, Osm3dGroundComposite,
  Osm3dCoastalCliffs;

type
  TWaterFeature = record
    MP: TPolygonMultipolygon;
    A, B: TVector3;
    MinX, MinZ, MaxX, MaxZ, Width: Double;
    Scale: Single;
    Linear: Boolean;
  end;

function WaterScaleForWidth(Width: Double; IsSea: Boolean): Single;
begin
  if IsSea then Exit(1);
  { Decimetre source width prevents tiny projection/codec roundoff from
    changing a wave's spatial frequency between independently baked tiles.
    The resulting scale has four decimal digits, identical after cache IO. }
  Result := Round(EnsureRange(Width,5.0,1000.0)*10.0) / 10000.0;
end;

function TileHasMarineWater(Model:TTileModel):Boolean;
var I,J:Integer;Rec:TTileMeshRec;
begin
  Result:=False;if Model=nil then Exit;
  for I:=0 to Model.MeshCount-1 do begin
    Rec:=Model.Meshes[I];
    for J:=0 to High(Rec.WaterScale)do
      if Rec.WaterScale[J]=-1 then Exit(True);
  end;
end;

function SeaTags(Tags: TOSMTags): Boolean;
var W, N, P: string;
begin
  W := Tags.GetLower('water'); N := Tags.GetLower('natural');
  P := Tags.GetLower('place');
  Result := (W = 'sea') or (W = 'ocean') or (N = 'bay') or
    (N = 'strait') or (P = 'sea') or (P = 'ocean');
end;

function SegmentDistance2(X, Z, AX, AZ, BX, BZ: Double): Double;
var DX, DZ, T, D: Double;
begin
  DX := BX - AX; DZ := BZ - AZ; D := DX*DX + DZ*DZ;
  if D > 1e-12 then T := EnsureRange(((X-AX)*DX+(Z-AZ)*DZ)/D, 0.0, 1.0)
  else T := 0;
  Result := Sqr(X-AX-T*DX) + Sqr(Z-AZ-T*DZ);
end;

function OnRing(X, Z: Double; const Ring: TPolygonRing): Boolean;
var I, J: Integer;
begin
  J := High(Ring);
  for I := 0 to High(Ring) do
  begin
    { Carve snaps to 1/64 m and caches coordinates to millimetres. }
    if SegmentDistance2(X,Z,Ring[J].X,Ring[J].Z,Ring[I].X,Ring[I].Z) < 0.0064 then Exit(True);
    J := I;
  end;
  Result := False;
end;

procedure BakeWaterScales(Dataset: TOSMDataset; const Origin: TLatLon;
  ScaleLat: Double; const Models: array of TTileModel);
var
  Features: array of TWaterFeature;
  Count, I, J, K, M, V, F, C, CandidateCount: Integer;
  Candidates: array of Integer;
  Projection: TLocalProjection;
  Way: TOSMWay; Rel: TOSMRelation; N0, N1: TOSMNode;
  Polys: array of TPolygonMultipolygon;
  Rec: TTileMeshRec; Vertices: TMeshVertexArray;
  Scales: TTileWaterScaleArray;
  X, Z, DX, DZ, BestWidth, Dist, BestDist: Double;
  TileMinX, TileMinZ, TileMaxX, TileMaxZ: Double;
  Value: Single;
  HasWater, Inside: Boolean;

  procedure Push(const Feature: TWaterFeature);
  begin
    if Count = Length(Features) then SetLength(Features, Max(32, Count*2));
    Features[Count] := Feature; Inc(Count);
  end;

  procedure AddPolygon(const MP: TPolygonMultipolygon; Tags: TOSMTags);
  var Item: TWaterFeature; A, P: Double; R: Integer;
    procedure Accumulate(const Ring: TPolygonRing; IsHole: Boolean);
    var Q, Prev: Integer; RingA: Double;
    begin
      RingA := 0; Prev := High(Ring);
      for Q := 0 to High(Ring) do
      begin
        RingA := RingA + Ring[Prev].X*Ring[Q].Z-Ring[Q].X*Ring[Prev].Z;
        P := P + Hypot(Ring[Q].X-Ring[Prev].X,Ring[Q].Z-Ring[Prev].Z);
        Prev := Q;
      end;
      if IsHole then A := A-Abs(RingA)*0.5 else A := A+Abs(RingA)*0.5;
    end;
  begin
    if Length(MP.Outer) < 3 then Exit;
    Item := Default(TWaterFeature); Item.MP := MP;
    Item.MinX := MP.Outer[0].X; Item.MaxX := Item.MinX;
    Item.MinZ := MP.Outer[0].Z; Item.MaxZ := Item.MinZ;
    for R := 1 to High(MP.Outer) do
    begin
      Item.MinX := Min(Item.MinX,MP.Outer[R].X); Item.MaxX := Max(Item.MaxX,MP.Outer[R].X);
      Item.MinZ := Min(Item.MinZ,MP.Outer[R].Z); Item.MaxZ := Max(Item.MaxZ,MP.Outer[R].Z);
    end;
    A := 0; P := 0; Accumulate(MP.Outer,False);
    for R := 0 to High(MP.Inners) do Accumulate(MP.Inners[R],True);
    { 2A/P approaches the cross-section width for long narrow polygons.
      Holes reduce open water. Both measurements use the uncut OSM contour. }
    Item.Width := Max(1.0, 2*Max(0.0,A)/Max(P,1.0));
    Item.Scale := WaterScaleForWidth(Item.Width, SeaTags(Tags));
    if SeaTags(Tags) then Item.Scale := -1; { unambiguous marine marker }
    Push(Item);
  end;

  procedure AddSegment(const A, B: TVector3; Width: Double);
  var Item: TWaterFeature;
  begin
    Item := Default(TWaterFeature); Item.Linear := True;
    Item.A := A; Item.B := B; Item.Width := Width;
    { Match BuildRibbon's maximum mitre extension at sharp bends. }
    Item.MinX := Min(A.X,B.X)-Width*1.5; Item.MaxX := Max(A.X,B.X)+Width*1.5;
    Item.MinZ := Min(A.Z,B.Z)-Width*1.5; Item.MaxZ := Max(A.Z,B.Z)+Width*1.5;
    Item.Scale := WaterScaleForWidth(Width,False);
    Push(Item);
  end;

begin
  if Dataset = nil then Exit;
  HasWater := False;
  for M := 0 to High(Models) do
    if Models[M] <> nil then
      for K := 0 to Models[M].MeshCount-1 do
      begin
        Rec := Models[M].Meshes[K];
        for V := 0 to High(Rec.MatIds) do
          if Rec.MatIds[V] = GROUND_MAT_WATER then begin HasWater := True; Break end;
      end;
  if not HasWater then Exit;
  Count := 0;
  Projection := TLocalProjection.Create(Origin,ScaleLat);
  try
    for Way in Dataset.Ways.Values do
    begin
      if Way = nil then Continue;
      if Way.IsClosed then
      begin
        if TLanduseBuilder.ClassifyTags(Way.Tags) = lkWater then
          AddPolygon(BuildMultipolygonFromWay(Way,Dataset,Projection),Way.Tags);
      end
      else if Way.Tags.HasKey('waterway') and (Way.Tags.GetLower('area') <> 'yes') then
        for I := 1 to High(Way.NodeRefs) do
        begin
          N0 := Dataset.FindNode(Way.NodeRefs[I-1]); N1 := Dataset.FindNode(Way.NodeRefs[I]);
          if (N0 <> nil) and (N1 <> nil) then
            AddSegment(Projection.Project(N0.Position),Projection.Project(N1.Position),
              TWaterBuilder.ClassifyWidth(Way.Tags));
        end;
    end;
    for Rel in Dataset.Relations.Values do
      if (Rel <> nil) and (TLanduseBuilder.ClassifyTags(Rel.Tags) = lkWater) and
        ((Rel.Tags.GetLower('type') = 'multipolygon') or (Rel.Tags.GetLower('type') = 'boundary')) then
      begin
        Polys := BuildMultipolygonsFromRelation(Rel,Dataset,Projection);
        for I := 0 to High(Polys) do AddPolygon(Polys[I],Rel.Tags);
      end;
    for M := 0 to High(Models) do
    begin
      if Models[M] = nil then Continue;
      { Tile vertices retain the bake's longitude metric, not session origin. }
      DX := -(Models[M].Origin.Lon-Origin.Lon)*Projection.MetersPerDegreeLon;
      DZ := (Models[M].Origin.Lat-Origin.Lat)*Projection.MetersPerDegreeLat;
      TileMinX := -(Models[M].Box.MaxLon-Origin.Lon)*Projection.MetersPerDegreeLon;
      TileMaxX := -(Models[M].Box.MinLon-Origin.Lon)*Projection.MetersPerDegreeLon;
      TileMinZ := (Models[M].Box.MinLat-Origin.Lat)*Projection.MetersPerDegreeLat;
      TileMaxZ := (Models[M].Box.MaxLat-Origin.Lat)*Projection.MetersPerDegreeLat;
      CandidateCount := 0; SetLength(Candidates,Count);
      for F := 0 to Count-1 do
        with Features[F] do
          if (MaxX >= TileMinX-0.08) and (MinX <= TileMaxX+0.08) and
             (MaxZ >= TileMinZ-0.08) and (MinZ <= TileMaxZ+0.08) then
          begin Candidates[CandidateCount] := F; Inc(CandidateCount) end;
      for K := 0 to Models[M].MeshCount-1 do
      begin
        Rec := Models[M].Meshes[K]; HasWater := False;
        for V := 0 to High(Rec.MatIds) do
          if Rec.MatIds[V] = GROUND_MAT_WATER then begin HasWater := True; Break end;
        if not HasWater then Continue;
        Vertices := Rec.Mesh.Vertices;
        Scales := nil; SetLength(Scales,Length(Vertices));
        for V := 0 to High(Vertices) do
        begin
          if Rec.MatIds[V] <> GROUND_MAT_WATER then Continue;
          X := Vertices[V].Position.X+DX; Z := Vertices[V].Position.Z+DZ;
          Value := WaterScaleForWidth(WIDTH_DEFAULT,False);
          BestWidth := 1e30; BestDist := 1e30;
          { Area contours take precedence over the often schematic river line. }
          for C := 0 to CandidateCount-1 do
            with Features[Candidates[C]] do
            begin
              if (X < MinX-0.08) or (X > MaxX+0.08) or (Z < MinZ-0.08) or (Z > MaxZ+0.08) then Continue;
              if Linear then
              begin
                if BestWidth < 1e30 then Continue;
                Dist := SegmentDistance2(X,Z,A.X,A.Z,B.X,B.Z);
                if (Dist <= Sqr(Width*1.5+0.08)) and (Dist < BestDist) then
                begin BestDist := Dist; Value := Scale end;
              end
              else
              begin
                if Width >= BestWidth then Continue;
                Inside := PointInRingXZ(X,Z,MP.Outer) or OnRing(X,Z,MP.Outer);
                if not Inside then Continue;
                for J := 0 to High(MP.Inners) do
                  if PointInRingXZ(X,Z,MP.Inners[J]) and not OnRing(X,Z,MP.Inners[J]) then
                  begin Inside := False; Break end;
                if Inside then begin BestWidth := Width; Value := Scale end;
              end;
            end;
          Scales[V] := Value;
          if Value = -1 then
          begin
            Vertices[V].Position.Y := 0; { sea level, not DEM bathymetry }
            Vertices[V].Normal := Vector3(0,1,0);
          end;
        end;
        Models[M].SetWaterScale(K,Scales);
      end;
      CloseCoastalCliffs(Dataset,Models[M],ScaleLat);
    end;
  finally
    Projection.Free;
  end;
end;

end.
