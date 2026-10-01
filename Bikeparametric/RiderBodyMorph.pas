unit RiderBodyMorph;

{$mode objfpc}{$H+}

{ Authored static shape fields. Applied only on profile changes, before GPU
  skinning; pose animation and facial animation keep their existing paths. }
interface

uses Classes, SysUtils, Math, fpjson, CastleVectors, X3DNodes,
  TripoRig, RiderBodyParameters;

type
  TRiderBodyMorph = class
  private
    type
      TVectors = array of TVector3;
      TShape = record
        Geometry: TAbstractComposedGeometryNode;
        Coord: TCoordinateNode;
        Normal: TNormalNode;
        First: Integer;
        Position, Normals: TVectors;
        DeltaP, DeltaN: array[0..4] of TVectors;
      end;
    var
      FShapes: array of TShape;
      FLast: TRiderBodyParameters;
      FApplied: Boolean;
      FRevision: Cardinal;
      FInseamVertex:Integer;
      FHasInseamPoint:Boolean;
      FInseamPoint,FInseamFitted:TVector3;
      FInseamDelta:array[0..4] of TVector3;
  public
    function Load(const Path: string; Skin: TSkinNode; Rig: TTripoRig): Boolean;
    function Apply(const Value: TRiderBodyParameters; Rig: TTripoRig): Boolean;
    procedure Measure(Rig:TTripoRig; out Height,Inseam:Single);
    property Revision: Cardinal read FRevision;
  end;

implementation

uses GltfCore, RiderCorrectiveData;

function TRiderBodyMorph.Load(const Path: string; Skin: TSkinNode;
  Rig: TTripoRig): Boolean;
var Data: TMemoryStream; Info, Item: TJSONObject; Shapes, Targets,PointData,DeltaData: TJSONArray;
  I, J, K, V, Count, First: Integer; Shape: TShapeNode; P: ^TShape;
begin
  Result := False;
  if (Skin=nil) or (Rig=nil) then Exit;
  Data := OpenRiderEmbeddedData(Path, 'riderBodyShape', Info);
  if Data=nil then Exit;
  try
    if Info.Get('version',0)<>1 then raise EReadError.Create('Unsupported rider body shape version');
    Shapes:=ArrOf(Info,'shapes'); Targets:=ArrOf(Info,'targets');
    if (Shapes=nil) or (Targets=nil) or (Targets.Count<>5) or
      (Info.Get('vertices',0)<>Rig.VertexCount) then
      raise EReadError.Create('Invalid rider body shape header');
    if Data.Size<>Int64(Rig.VertexCount)*5*2*SizeOf(TVector3) then
      raise EReadError.Create('Invalid rider body shape length');
    SetLength(FShapes,Shapes.Count);
    FInseamVertex:=Info.Get('inseamVertex',-1);
    if (FInseamVertex<0) or (FInseamVertex>=Rig.VertexCount) then
      raise EReadError.Create('Invalid rider inseam reference');
    FHasInseamPoint:=False;
    PointData:=ArrOf(Info,'inseamPoint');DeltaData:=ArrOf(Info,'inseamDeltas');
    if (PointData<>nil) or (DeltaData<>nil) then begin
      if (PointData=nil) or (PointData.Count<>3) or (DeltaData=nil) or (DeltaData.Count<>5) then
        raise EReadError.Create('Invalid rider anatomical inseam point');
      FInseamPoint:=Vector3(PointData.Floats[0],PointData.Floats[1],PointData.Floats[2]);
      for K:=0 to 4 do begin
        PointData:=DeltaData.Arrays[K];
        if PointData.Count<>3 then raise EReadError.Create('Invalid rider anatomical inseam delta');
        FInseamDelta[K]:=Vector3(PointData.Floats[0],PointData.Floats[1],PointData.Floats[2]);
      end;
      FInseamFitted:=FInseamPoint;FHasInseamPoint:=True;
    end;
    First:=0;
    for I:=0 to Shapes.Count-1 do
    begin
      Item:=Shapes.Objects[I]; Count:=Item.Get('vertices',0);
      if (Count<=0) or (First+Count>Rig.VertexCount) or
        (Item.Get('first',-1)<>First) then raise EReadError.Create('Invalid rider body vertex range');
      Shape:=nil;
      for J:=0 to Skin.FdShapes.Count-1 do
        if (Skin.FdShapes[J] is TShapeNode) and
          (Skin.FdShapes[J].X3DName=Item.Get('name','')) then
          Shape:=TShapeNode(Skin.FdShapes[J]);
      if (Shape=nil) or not (Shape.Geometry is TAbstractComposedGeometryNode) then
        raise EReadError.Create('Missing rider body mesh: '+Item.Get('name',''));
      P:=@FShapes[I]; P^.Geometry:=TAbstractComposedGeometryNode(Shape.Geometry);
      if not (P^.Geometry.FdCoord.Value is TCoordinateNode) or
        not (P^.Geometry.FdNormal.Value is TNormalNode) then
        raise EReadError.Create('Missing rider body positions/normals');
      P^.Coord:=TCoordinateNode(P^.Geometry.FdCoord.Value);
      P^.Normal:=TNormalNode(P^.Geometry.FdNormal.Value);
      if (P^.Coord.FdPoint.Count<>Count) or (P^.Normal.FdVector.Count<>Count) then
        raise EReadError.Create('Rider body vertex count mismatch');
      P^.First:=First; Inc(First,Count);
      SetLength(P^.Position,Count); SetLength(P^.Normals,Count);
      for V:=0 to Count-1 do
      begin
        P^.Position[V]:=P^.Coord.FdPoint.Items[V];
        P^.Normals[V]:=P^.Normal.FdVector.Items[V];
      end;
      for K:=0 to 4 do
      begin
        SetLength(P^.DeltaP[K],Count); SetLength(P^.DeltaN[K],Count);
        Data.ReadBuffer(P^.DeltaP[K][0],Count*SizeOf(TVector3));
        Data.ReadBuffer(P^.DeltaN[K][0],Count*SizeOf(TVector3));
      end;
    end;
    if First<>Rig.VertexCount then raise EReadError.Create('Incomplete rider body shape');
    Result:=True;
  finally Info.Free; Data.Free end;
end;

procedure TRiderBodyMorph.Measure(Rig:TTripoRig;out Height,Inseam:Single);
var M:array of TTripoMat4; P,Q:TTripoVec3;
  V,J,K:Integer; Bottom,Top,Crotch:Single;
begin
  SetLength(M,Rig.JointCount);
  for J:=0 to Rig.JointCount-1 do M[J]:=Mat4Mul(Rig.BindWorld[J],Rig.InvBind[J]);
  Bottom:=1E10;Top:=-1E10;Crotch:=0;
  for V:=0 to Rig.VertexCount-1 do begin
    P:=V3(0,0,0);
    for K:=0 to 3 do begin
      Q:=Mat4MulPoint(M[Rig.Joints[V][K]],Rig.Positions[V]);
      P:=V3Add(P,V3Scale(Q,Rig.Weights[V][K]));
    end;
    Bottom:=Min(Bottom,P.Y);Top:=Max(Top,P.Y);
    if V=FInseamVertex then begin
      if FHasInseamPoint then begin
        { Garment padding is outside the body. Keep anatomical measurements
          independent of its thickness, using the same fitted bind frame. }
        P:=V3(0,0,0);
        for K:=0 to 3 do begin
          Q:=Mat4MulPoint(M[Rig.Joints[V][K]],V3(FInseamFitted.X,FInseamFitted.Y,FInseamFitted.Z));
          P:=V3Add(P,V3Scale(Q,Rig.Weights[V][K]));
        end;
      end;
      Crotch:=P.Y;
    end;
  end;
  Height:=Top-Bottom;Inseam:=Crotch-Bottom;
end;

function TRiderBodyMorph.Apply(const Value: TRiderBodyParameters; Rig:TTripoRig):Boolean;
var P:TRiderBodyParameters; C:array[0..4] of Single;
  I,V,K,R:Integer; Position,Normal:TVector3; S:^TShape;
begin
  Result:=False; P:=NormalizeRiderBody(Value);
  if FApplied and SameRiderBody(P,FLast) then Exit;
  C[0]:=1-P.Sex; C[4]:=1-P.HeadShape;
  RiderBodyShapeWeights(P,C[1],C[2],C[3]);
  if FHasInseamPoint then begin
    FInseamFitted:=FInseamPoint;
    for K:=0 to 4 do FInseamFitted:=FInseamFitted+FInseamDelta[K]*C[K];
  end;
  for I:=0 to High(FShapes) do
  begin
    S:=@FShapes[I];
    for V:=0 to High(S^.Position) do
    begin
      Position:=S^.Position[V]; Normal:=S^.Normals[V];
      for K:=0 to 4 do
      begin
        Position:=Position+S^.DeltaP[K][V]*C[K];
        Normal:=Normal+S^.DeltaN[K][V]*C[K];
      end;
      Normal:=Normal.Normalize;
      S^.Coord.FdPoint.Items[V]:=Position;
      S^.Normal.FdVector.Items[V]:=Normal;
      { CPU fallback stores a separate rest copy; update it as well, never bake
        a previously animated vertex into the next static profile. }
      if S^.Geometry.InternalOriginalCoords<>nil then
        S^.Geometry.InternalOriginalCoords[V]:=Position;
      if S^.Geometry.InternalOriginalNormals<>nil then
        S^.Geometry.InternalOriginalNormals[V]:=Normal;
      R:=S^.First+V;
      Rig.Positions[R]:=V3(Position.X,Position.Y,Position.Z);
      Rig.Normals[R]:=V3(Normal.X,Normal.Y,Normal.Z);
    end;
    S^.Coord.FdPoint.Changed;
    S^.Normal.FdVector.Changed;
  end;
  FLast:=P; FApplied:=True; Inc(FRevision); Result:=True;
end;

end.
