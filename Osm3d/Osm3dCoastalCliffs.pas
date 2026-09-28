unit Osm3dCoastalCliffs;

{$mode objfpc}{$H+}

interface

uses Osm3dOsmData, Osm3dGeoMath, Osm3dTileX3D;

{ Close the exposed land edge down to sea level. Only real OSM coastline
  segments qualify: tile frames and inland water must never grow walls. }
procedure CloseCoastalCliffs(Dataset: TOSMDataset; Model: TTileModel;
  ScaleLat: Double);

implementation

uses Math, SysUtils, Generics.Collections, CastleVectors, Osm3dGeomMesh,
  Osm3dGroundComposite;

type
  TCoastSegment = record
    A, B: TVector3;
  end;
  TEdgeSet = specialize TDictionary<QWord, Boolean>;

procedure CloseCoastalCliffs(Dataset: TOSMDataset; Model: TTileModel;
  ScaleLat: Double);
var
  Segments: array of TCoastSegment;
  Pr: TLocalProjection;
  Way: TOSMWay;
  ANode, BNode: TOSMNode;
  SegCount, I, J, K, E, IA, IB, PA, PB, Base, OldCount: Integer;
  Rec: TTileMeshRec;
  V: TMeshVertexArray;
  Ind: TMeshIndexArray;
  OnCoast: array of Boolean;
  MatIds: TTileMatIdArray;
  Scale: TTileWaterScaleArray;
  Pool: TVertexPool;
  Seen: TEdgeSet;
  Cliffs: TMesh;
  A, B, N, BottomA, BottomB: TVector3;
  Len, MinX, MaxX, MinZ, MaxZ: Double;
  Key: QWord;
  Marine: Boolean;

  function IsCoast(const P: TVector3): Boolean;
  var S: Integer; DX, DZ, T, D: Double;
  begin
    for S := 0 to SegCount-1 do
      with Segments[S] do
      begin
        if (P.X < Min(A.X,B.X)-0.08) or (P.X > Max(A.X,B.X)+0.08) or
           (P.Z < Min(A.Z,B.Z)-0.08) or (P.Z > Max(A.Z,B.Z)+0.08) then Continue;
        DX := B.X-A.X; DZ := B.Z-A.Z; D := DX*DX+DZ*DZ;
        if D < 1e-12 then Continue;
        T := EnsureRange(((P.X-A.X)*DX+(P.Z-A.Z)*DZ)/D,0.0,1.0);
        if Sqr(P.X-A.X-T*DX)+Sqr(P.Z-A.Z-T*DZ) <= 0.0064 then Exit(True);
      end;
    Result := False;
  end;

begin
  if (Dataset = nil) or (Model = nil) then Exit;
  Marine := False;
  for K := 0 to Model.MeshCount-1 do
  begin
    Rec := Model.Meshes[K];
    for I := 0 to High(Rec.WaterScale) do
      if Rec.WaterScale[I] = -1 then begin Marine := True; Break end;
    if Marine then Break;
  end;
  if not Marine then Exit;
  Pr := TLocalProjection.Create(Model.Origin,ScaleLat);
  Pool := nil; Seen := nil; Cliffs := nil;
  try
    MinX := -(Model.Box.MaxLon-Model.Origin.Lon)*Pr.MetersPerDegreeLon;
    MaxX := -(Model.Box.MinLon-Model.Origin.Lon)*Pr.MetersPerDegreeLon;
    MinZ := (Model.Box.MinLat-Model.Origin.Lat)*Pr.MetersPerDegreeLat;
    MaxZ := (Model.Box.MaxLat-Model.Origin.Lat)*Pr.MetersPerDegreeLat;
    SegCount := 0;
    for Way in Dataset.Ways.Values do
      if (Way <> nil) and (Way.Tags.GetLower('natural') = 'coastline') then
        for I := 1 to High(Way.NodeRefs) do
        begin
          ANode := Dataset.FindNode(Way.NodeRefs[I-1]);
          BNode := Dataset.FindNode(Way.NodeRefs[I]);
          if (ANode = nil) or (BNode = nil) then Continue;
          A := Pr.Project(ANode.Position); B := Pr.Project(BNode.Position);
          if (Max(A.X,B.X) < MinX-0.08) or (Min(A.X,B.X) > MaxX+0.08) or
             (Max(A.Z,B.Z) < MinZ-0.08) or (Min(A.Z,B.Z) > MaxZ+0.08) then Continue;
          if SegCount = Length(Segments) then SetLength(Segments,Max(32,SegCount*2));
          Segments[SegCount].A := A; Segments[SegCount].B := B; Inc(SegCount);
        end;
    if SegCount = 0 then Exit;
    Pool := TVertexPool.Create(0.001,0.999,256);
    Seen := TEdgeSet.Create;
    for K := 0 to Model.MeshCount-1 do
    begin
      Rec := Model.Meshes[K];
      if (Rec.Mesh = nil) or (Length(Rec.MatIds) <> Rec.Mesh.VertexCount) then Continue;
      V := Rec.Mesh.Vertices; Ind := Rec.Mesh.Indices;
      SetLength(OnCoast,Length(V));
      for I := 0 to High(V) do
        OnCoast[I] := (Rec.MatIds[I] <> GROUND_MAT_WATER) and IsCoast(V[I].Position);
      Cliffs := TMesh.Create('coastal_cliffs');
      for J := 0 to Length(Ind) div 3-1 do
        for E := 0 to 2 do
        begin
          IA := Ind[J*3+E]; IB := Ind[J*3+(E+1) mod 3];
          if not (OnCoast[IA] and OnCoast[IB]) then Continue;
          A := V[IA].Position; B := V[IB].Position;
          if (Max(A.Y,B.Y) <= 0.03) or not IsCoast((A+B)*0.5) then Continue;
          Len := Hypot(B.X-A.X,B.Z-A.Z);
          if Len < 0.01 then Continue;
          PA := Pool.Add(Vector3(A.X,0,A.Z),Vector3(0,1,0));
          PB := Pool.Add(Vector3(B.X,0,B.Z),Vector3(0,1,0));
          Key := (QWord(Min(PA,PB)) shl 32) or QWord(Max(PA,PB));
          if Seen.ContainsKey(Key) then Continue;
          Seen.Add(Key,True);
          { A->B follows the land triangle boundary. The outside is its
            right-hand side when viewed from above. Preserve the land top. }
          N := Vector3(-(B.Z-A.Z)/Len,0,(B.X-A.X)/Len);
          BottomA := Vector3(A.X,Min(-0.5,A.Y),A.Z);
          BottomB := Vector3(B.X,Min(-0.5,B.Y),B.Z);
          Base := Cliffs.VertexCount;
          Cliffs.AddVertex(A,N,Vector2(0,A.Y/4));
          Cliffs.AddVertex(B,N,Vector2(Len/4,B.Y/4));
          Cliffs.AddVertex(BottomB,N,Vector2(Len/4,BottomB.Y/4));
          Cliffs.AddVertex(BottomA,N,Vector2(0,BottomA.Y/4));
          Cliffs.AddQuad(Base,Base+1,Base+2,Base+3);
        end;
      if Cliffs.VertexCount > 0 then
      begin
        Cliffs.MakeWindingMatchNormals;
        OldCount := Rec.Mesh.VertexCount;
        Rec.Mesh.AppendMesh(Cliffs);
        MatIds := Copy(Rec.MatIds); SetLength(MatIds,Rec.Mesh.VertexCount);
        for I := OldCount to High(MatIds) do MatIds[I] := GROUND_MAT_ROCK;
        Model.SetMaterialIds(K,MatIds);
        Scale := Copy(Rec.WaterScale);
        if Length(Scale) > 0 then
        begin SetLength(Scale,Rec.Mesh.VertexCount); Model.SetWaterScale(K,Scale) end;
      end;
      FreeAndNil(Cliffs);
    end;
  finally
    Cliffs.Free; Seen.Free; Pool.Free; Pr.Free;
  end;
end;

end.
