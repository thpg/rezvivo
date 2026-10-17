unit RiderLod;
{$mode objfpc}{$H+}
{ Offline topology maps, one shared rig/material set. Compact vertex buffers
  also reduce transform-feedback skinning work. No model reload at transitions. }
interface
uses Classes,SysUtils,Math,fpjson,CastleVectors,CastleScene,CastleRenderOptions,
  CastleRenderContext,CastleTransform,CastleTimeUtils,CastleSceneCore,CastleShapes,
  X3DNodes,X3DFields;
type
  TRiderLod=class
  private
    type
      TPart=record
        Source:TShapeNode;
        Shapes:array[1..2]of TShapeNode;
        Maps:array[1..2]of array of Cardinal;
      end;
      TMembership=record
        Shape:TAbstractShapeNode;
        Part,Level:Integer;
        Alive:Boolean;
      end;
      TBatch=record
        Source:array[0..1]of TShapeNode;
        Shape:TShapeNode;
        Level:Integer;
        Valid:Boolean;
      end;
      TBatchDependency=record
        Node:TX3DNode;
        Batches:array of Integer;
      end;
    var
      FScene:TCastleScene;
      FSkin:TSkinNode;
      FParts:array of TPart;
      FMembership:array of TMembership;
      FSelected,FBatchSelected:array of Boolean;
      FSelectionRevision:QWord;
      FSelectionLevel:Integer;
      FSelectionValid:Boolean;
      FUseMembership:Boolean;
      FPrevious:TRenderShapeFilter;
      FLevel:Integer;
      FPixels,FDistance:Single;
      FDirty:Boolean;
      FAttached:Boolean;
      FFilterAttached,FBatchActive:Boolean;
      FBatches:array of TBatch;
      FBatchDependencies:array of TBatchDependency;
      FDependencyBatch,FOwnChangeDepth:Integer;
      FGeometryObserverAttached:Boolean;
      FPreviousGeometryChanged:TSceneGeometryChanged;
      FProjectionFrame:TFrameId;
      FTriangles,FVertices:array[0..2]of Integer;
    function Filter(const Shape:TAbstractShapeNode;const Params:TRenderParams):Boolean;
    procedure BuildMembership;
    function FindMembership(const Shape:TAbstractShapeNode):Integer;
    procedure RefreshSelection;
    procedure CopyVertices(var P:TPart;Level:Integer;CreateNodes:Boolean);
    function BatchAllowed(const Index:Integer):Boolean;
    function SuppressedByBatch(const Shape:TAbstractShapeNode):Boolean;
    procedure ClearBatchDependencies;
    procedure AddBatchDependency(const Node:TX3DNode;const Batch:Integer);
    procedure AddGeometryDependency(Node:TX3DNode);
    procedure CaptureBatchDependencies;
    procedure BatchFieldChanged(const Node:TX3DNode;const Field:TX3DField);
    procedure BatchNodeDestroyed(const Node:TX3DNode);
    procedure BatchGeometryChanged(Scene:TCastleSceneCore;
      const LocalGeometryChanged:Boolean;OnlyShapeChanged:TShape);
    procedure InvalidateBatchNode(const Node:TX3DNode);
    procedure InvalidateAllBatches;
    function BatchParentsCompatible(const Index:Integer):Boolean;
  public
    constructor Create(Scene:TCastleScene;Skin:TSkinNode;const Path:string);
    destructor Destroy;override;
    procedure Invalidate;
    procedure Update;
    procedure BuildBatches;
    procedure SetBatchActive(const Value:Boolean);
    function DebugJson:TJSONObject;
  end;
var
  RiderLodOverride:Integer=-1; { -1 automatic, 0 full, 1 medium, 2 far; diagnostics }
implementation
uses GltfCore,RiderCorrectiveData,RiderGeometryMerge;

function LodTexCoord(Source:TAbstractTextureCoordinateNode;const Map:array of Cardinal):TAbstractTextureCoordinateNode;
var I:Integer;UV:TTextureCoordinateNode;Multi:TMultiTextureCoordinateNode;
begin
  Result:=nil;
  if Source is TTextureCoordinateNode then begin
    UV:=TTextureCoordinateNode.Create;UV.Mapping:=TTextureCoordinateNode(Source).Mapping;
    UV.FdPoint.Items.Count:=Length(Map);
    for I:=0 to High(Map)do UV.FdPoint.Items[I]:=TTextureCoordinateNode(Source).FdPoint.Items[Map[I]];
    Result:=UV;
  end else if Source is TMultiTextureCoordinateNode then begin
    Multi:=TMultiTextureCoordinateNode.Create;
    for I:=0 to TMultiTextureCoordinateNode(Source).FdTexCoord.Count-1 do
      Multi.FdTexCoord.Add(LodTexCoord(TAbstractTextureCoordinateNode(TMultiTextureCoordinateNode(Source).FdTexCoord[I]),Map));
    Result:=Multi;
  end;
end;

procedure TRiderLod.CopyVertices(var P:TPart;Level:Integer;CreateNodes:Boolean);
var S,D:TAbstractComposedGeometryNode;C:TCoordinateNode;N:TNormalNode;
  T:TTangentNode;A,B:TFloatVertexAttributeNode;
  I,J,K,V:Integer;
begin
  S:=TAbstractComposedGeometryNode(P.Source.Geometry);
  D:=TAbstractComposedGeometryNode(P.Shapes[Level].Geometry);
  if CreateNodes then begin
    D.Coord:=TCoordinateNode.Create;D.Normal:=TNormalNode.Create;
    if S.Tangent<>nil then D.Tangent:=TTangentNode.Create;
    D.TexCoord:=LodTexCoord(S.TexCoord,P.Maps[Level]);
    if S.Color is TColorRGBANode then begin
      D.Color:=TColorRGBANode.Create;
      for I:=0 to High(P.Maps[Level])do TColorRGBANode(D.Color).FdColor.Items.Add(
        TColorRGBANode(S.Color).FdColor.Items[P.Maps[Level][I]]);
    end else if S.Color is TColorNode then begin
      D.Color:=TColorNode.Create;
      for I:=0 to High(P.Maps[Level])do TColorNode(D.Color).FdColor.Items.Add(
        TColorNode(S.Color).FdColor.Items[P.Maps[Level][I]]);
    end;
    for I:=0 to S.FdAttrib.Count-1 do if S.FdAttrib[I]is TFloatVertexAttributeNode then begin
      A:=TFloatVertexAttributeNode(S.FdAttrib[I]);B:=TFloatVertexAttributeNode.Create;
      B.NameField:=A.NameField;B.NumComponents:=A.NumComponents;D.FdAttrib.Add(B);
    end;
  end;
  C:=TCoordinateNode(D.Coord);N:=TNormalNode(D.Normal);T:=D.Tangent;
  C.FdPoint.Items.Count:=Length(P.Maps[Level]);N.FdVector.Items.Count:=C.FdPoint.Count;
  if T<>nil then T.FdVector.Items.Count:=C.FdPoint.Count;
  D.FdSkinWeights0.Items.Count:=C.FdPoint.Count;D.FdSkinJoints0.Items.Count:=C.FdPoint.Count*4;
  for I:=0 to High(P.Maps[Level])do begin
    V:=P.Maps[Level][I];
    if S.InternalOriginalCoords<>nil then C.FdPoint.Items[I]:=S.InternalOriginalCoords[V]
    else C.FdPoint.Items[I]:=TCoordinateNode(S.Coord).FdPoint.Items[V];
    if S.InternalOriginalNormals<>nil then N.FdVector.Items[I]:=S.InternalOriginalNormals[V]
    else N.FdVector.Items[I]:=TNormalNode(S.Normal).FdVector.Items[V];
    if T<>nil then begin
      if S.InternalOriginalTangents<>nil then T.FdVector.Items[I]:=S.InternalOriginalTangents[V]
      else T.FdVector.Items[I]:=S.Tangent.FdVector.Items[V];
    end;
    D.FdSkinWeights0.Items[I]:=S.FdSkinWeights0.Items[V];
    for J:=0 to 3 do D.FdSkinJoints0.Items[I*4+J]:=S.FdSkinJoints0.Items[V*4+J];
  end;
  K:=0;
  for I:=0 to S.FdAttrib.Count-1 do if S.FdAttrib[I]is TFloatVertexAttributeNode then begin
    A:=TFloatVertexAttributeNode(S.FdAttrib[I]);B:=TFloatVertexAttributeNode(D.FdAttrib[K]);Inc(K);
    B.FdValue.Items.Count:=Length(P.Maps[Level])*A.NumComponents;
    for V:=0 to High(P.Maps[Level])do for J:=0 to A.NumComponents-1 do
      B.FdValue.Items[V*A.NumComponents+J]:=A.FdValue.Items[P.Maps[Level][V]*A.NumComponents+J];
    if not CreateNodes then B.FdValue.Changed;
  end;
  if D.InternalOriginalCoords<>nil then D.InternalOriginalCoords.Assign(C.FdPoint.Items);
  if D.InternalOriginalNormals<>nil then D.InternalOriginalNormals.Assign(N.FdVector.Items);
  if(T<>nil)and(D.InternalOriginalTangents<>nil)then D.InternalOriginalTangents.Assign(T.FdVector.Items);
  if not CreateNodes then begin C.FdPoint.Changed;N.FdVector.Changed end;
end;

constructor TRiderLod.Create(Scene:TCastleScene;Skin:TSkinNode;const Path:string);
var Data:TMemoryStream;Info,O,L:TJSONObject;Shapes,Levels:TJSONArray;
  I,J,K,Q,OriginalCount,VC,IC,N:Integer;Offset:Int64;V:Cardinal;
  S:TShapeNode;G,D:TIndexedTriangleSetNode;Valid:Boolean;
begin
  inherited Create;FScene:=Scene;FSkin:=Skin;
  FUseMembership:=GetEnvironmentVariable('REZVIVO_RIDER_MEMBERSHIP')<>'0';
  if(Skin=nil)or(Scene=nil)then Exit;
  if GetEnvironmentVariable('REZVIVO_TEST_RIDER_LOD')='0'then Exit;
  Data:=OpenRiderEmbeddedData(Path,'riderLod',Info);if Data=nil then Exit;
  try
    if Info.Get('version',0)<>1 then raise EReadError.Create('Unsupported rider LOD version');
    Shapes:=ArrOf(Info,'shapes');if(Shapes=nil)or(Shapes.Count>256)then Exit;
    OriginalCount:=Skin.FdShapes.Count;
    for I:=0 to Shapes.Count-1 do begin
      O:=Shapes.Objects[I];S:=nil;
      for J:=0 to OriginalCount-1 do if(Skin.FdShapes[J]is TShapeNode)and
        ((Skin.FdShapes[J].X3DName=O.Get('name',''))or
         (Skin.FdShapes[J].X3DName=O.Get('name','')+'_Primitive0'))then S:=TShapeNode(Skin.FdShapes[J]);
      if(S=nil)or not(S.Geometry is TIndexedTriangleSetNode)then Continue;
      G:=TIndexedTriangleSetNode(S.Geometry);
      if not(G.Coord is TCoordinateNode)or not(G.Normal is TNormalNode)then Continue;
      VC:=TCoordinateNode(G.Coord).FdPoint.Count;
      if(VC<>O.Get('source_vertices',0))or(G.FdIndex.Count<>O.Get('source_indices',0))then Continue;
      if(G.FdSkinWeights0.Count<>VC)or(G.FdSkinJoints0.Count<>VC*4)or
        ((G.TexCoord<>nil)and not(G.TexCoord is TTextureCoordinateNode)and
         not(G.TexCoord is TMultiTextureCoordinateNode))or
        ((G.Color<>nil)and not(G.Color is TColorNode)and not(G.Color is TColorRGBANode))then Continue;
      Valid:=True;
      for J:=0 to G.FdAttrib.Count-1 do
        if not(G.FdAttrib[J]is TFloatVertexAttributeNode)then Valid:=False
        else with TFloatVertexAttributeNode(G.FdAttrib[J])do
          if FdValue.Count<>VC*NumComponents then Valid:=False;
      if not Valid then Continue;
      Levels:=ArrOf(O,'levels');if(Levels=nil)or(Levels.Count<>2)then Continue;
      N:=Length(FParts);SetLength(FParts,N+1);FParts[N].Source:=S;
      Inc(FTriangles[0],G.FdIndex.Count div 3);Inc(FVertices[0],VC);
      for K:=1 to 2 do begin
        L:=Levels.Objects[K-1];Q:=L.Get('vertices',0);IC:=L.Get('indices',0);Offset:=L.Get('offset',Int64(-1));
        if(Q<=0)or(Q>VC)or(IC<3)or(IC>G.FdIndex.Count)or(IC mod 3<>0)or
          (Offset<0)or(Offset+Int64(Q+IC)*4>Data.Size)then raise EReadError.Create('Invalid rider LOD range');
        Data.Position:=Offset;SetLength(FParts[N].Maps[K],Q);
        Data.ReadBuffer(FParts[N].Maps[K][0],Q*4);
        for J:=0 to Q-1 do if FParts[N].Maps[K][J]>=Cardinal(VC)then raise EReadError.Create('Invalid rider LOD vertex');
        FParts[N].Shapes[K]:=TShapeNode.Create('RiderLOD'+IntToStr(K)+'_'+S.X3DName);
        FParts[N].Shapes[K].BBox:=S.BBox;
        FParts[N].Shapes[K].Shading:=S.Shading;
        FParts[N].Shapes[K].Collision:=S.Collision;
        D:=TIndexedTriangleSetNode.Create;FParts[N].Shapes[K].Geometry:=D;
        FParts[N].Shapes[K].Appearance:=S.Appearance;
        D.Solid:=G.Solid;D.CCW:=G.CCW;D.NormalPerVertex:=G.NormalPerVertex;D.ColorPerVertex:=G.ColorPerVertex;
        D.FdIndex.Items.Count:=IC;
        for J:=0 to IC-1 do begin
          Data.ReadBuffer(V,4);if V>=Cardinal(Q)then raise EReadError.Create('Invalid rider LOD index');
          D.FdIndex.Items[J]:=V;
        end;
        CopyVertices(FParts[N],K,True);
        Inc(FTriangles[K],IC div 3);Inc(FVertices[K],Q);
      end;
    end;
    { All source metadata/morphs are already bound. Derived shapes do not own
      new materials, effects, textures, rig or animation controllers. }
    Scene.BeginChangesSchedule;
    try
      for I:=0 to High(FParts)do for K:=1 to 2 do Skin.FdShapes.Add(FParts[I].Shapes[K]);
    finally Scene.EndChangesSchedule end;
    FAttached:=True;
    BuildMembership;
    FPrevious:=Scene.OnRenderShapeFilter;Scene.OnRenderShapeFilter:=@Filter;FFilterAttached:=True;
  finally Info.Free;Data.Free end;
end;

procedure TRiderLod.BuildMembership;
var I,K,N,J:Integer;Entry:TMembership;
begin
  { Nodes are owned by this scene for the entire table lifetime. No cross-scene
    pointer cache and no cached filter result: wardrobe visibility and the
    previous filter must still run in the current pass. }
  SetLength(FMembership,Length(FParts)*3);N:=0;
  for I:=0 to High(FParts)do for K:=0 to 2 do begin
    if K=0 then Entry.Shape:=FParts[I].Source else Entry.Shape:=FParts[I].Shapes[K];
    Entry.Part:=I;Entry.Level:=K;Entry.Alive:=Entry.Shape<>nil;J:=N;
    while (J>0) and (PtrUInt(FMembership[J-1].Shape)>PtrUInt(Entry.Shape))do begin
      FMembership[J]:=FMembership[J-1];Dec(J);
    end;
    FMembership[J]:=Entry;Inc(N);
  end;
  SetLength(FSelected,Length(FMembership));FSelectionValid:=False;
end;

function TRiderLod.FindMembership(const Shape:TAbstractShapeNode):Integer;
var L,H,M:Integer;Key,Found:PtrUInt;
begin
  Key:=PtrUInt(Shape);L:=0;H:=High(FMembership);
  while L<=H do begin
    M:=L+(H-L)div 2;Found:=PtrUInt(FMembership[M].Shape);
    if Found=Key then begin
      if FMembership[M].Alive then Exit(M)else Exit(-1);
    end;
    if Found<Key then L:=M+1 else H:=M-1;
  end;
  Result:=-1;
end;

destructor TRiderLod.Destroy;
var I,K:Integer;
begin
  ClearBatchDependencies;
  if FGeometryObserverAttached and(FScene<>nil)and
    (TMethod(FScene.OnGeometryChanged).Data=Pointer(Self))then
    FScene.OnGeometryChanged:=FPreviousGeometryChanged;
  if(FScene<>nil)and(TMethod(FScene.OnRenderShapeFilter).Data=Pointer(Self))then
    FScene.OnRenderShapeFilter:=FPrevious;
  { The scene owns all clones and frees them with the source graph. Do not
    emit live ChangedAll notifications while GPU controllers are tearing down. }
  if not FAttached then for I:=0 to High(FParts)do for K:=1 to 2 do
    if FParts[I].Shapes[K]<>nil then FParts[I].Shapes[K].FreeIfUnused;
  inherited;
end;

procedure TRiderLod.Invalidate;
begin FDirty:=True end;
procedure TRiderLod.SetBatchActive(const Value:Boolean);
begin
  if FBatchActive=Value then Exit;
  FBatchActive:=Value;FSelectionValid:=False;
end;

procedure TRiderLod.InvalidateAllBatches;
var I:Integer;
begin
  for I:=0 to High(FBatches)do FBatches[I].Valid:=False;
  FSelectionValid:=False;
end;

procedure TRiderLod.InvalidateBatchNode(const Node:TX3DNode);
var I,J:Integer;
begin
  { This runs only when an explicitly watched node changes, never once per
    shape/pass/frame. No geometry hashing or whole-scene dependency scan. }
  for I:=0 to High(FBatchDependencies)do
    if FBatchDependencies[I].Node=Node then begin
      for J:=0 to High(FBatchDependencies[I].Batches)do
        FBatches[FBatchDependencies[I].Batches[J]].Valid:=False;
      FSelectionValid:=False;Exit;
    end;
end;

function TRiderLod.BatchParentsCompatible(const Index:Integer):Boolean;
var J,M:Integer;S:TShapeNode;
  function DirectChild(const N:TX3DNode):Boolean;
  begin
    Result:=(N<>nil)and(FSkin<>nil)and(N.ParentFieldsCount=1)and
      (N.ParentFields[0]=FSkin.FdShapes);
  end;
begin
  Result:=False;
  if not DirectChild(FBatches[Index].Shape)then Exit;
  for J:=0 to 1 do begin
    S:=FBatches[Index].Source[J];if not DirectChild(S)then Exit;
    M:=FindMembership(S);
    if(M>=0)and not DirectChild(FParts[FMembership[M].Part].Source)then Exit;
  end;
  Result:=True;
end;

procedure TRiderLod.BatchFieldChanged(const Node:TX3DNode;const Field:TX3DField);
var I:Integer;
begin
  if FOwnChangeDepth<>0 then Exit;
  if Node=FSkin then begin
    { The shared Skin transform/rig moves both sources and batch identically.
      Reparenting a source destroys that contract; unrelated children do not. }
    if Field=FSkin.FdShapes then begin
      for I:=0 to High(FBatches)do
        if not BatchParentsCompatible(I)then FBatches[I].Valid:=False;
      FSelectionValid:=False;
    end;
    Exit;
  end;
  if(Node is TShapeNode)and(Field=TShapeNode(Node).FdVisible)then begin
    FSelectionValid:=False;Exit;
  end;
  InvalidateBatchNode(Node);
end;

procedure TRiderLod.BatchNodeDestroyed(const Node:TX3DNode);
var I,J:Integer;
begin
  { Destruction observers only invalidate/null references. In particular they
    never remove listeners or free nodes while the node dispatch is active. }
  InvalidateBatchNode(Node);
  for I:=0 to High(FBatchDependencies)do
    if FBatchDependencies[I].Node=Node then FBatchDependencies[I].Node:=nil;
  if Node=FSkin then begin FSkin:=nil;InvalidateAllBatches end;
  for I:=0 to High(FBatches)do begin
    for J:=0 to 1 do if FBatches[I].Source[J]=Node then FBatches[I].Source[J]:=nil;
    if FBatches[I].Shape=Node then FBatches[I].Shape:=nil;
  end;
  for I:=0 to High(FParts)do begin
    if FParts[I].Source=Node then FParts[I].Source:=nil;
    for J:=1 to 2 do if FParts[I].Shapes[J]=Node then FParts[I].Shapes[J]:=nil;
  end;
  { Keep the sorted pointer key as a tombstone, never dereference it or let a
    newly allocated unrelated node at that address inherit old membership. }
  for I:=0 to High(FMembership)do
    if FMembership[I].Shape=Node then FMembership[I].Alive:=False;
  FSelectionValid:=False;
end;

procedure TRiderLod.BatchGeometryChanged(Scene:TCastleSceneCore;
  const LocalGeometryChanged:Boolean;OnlyShapeChanged:TShape);
begin
  if(FOwnChangeDepth=0)and LocalGeometryChanged then begin
    if OnlyShapeChanged=nil then
      { ChangedAll also supports raw array edits without individual Changed
        calls. It deliberately has no narrower dependency information. }
      InvalidateAllBatches
    else InvalidateBatchNode(OnlyShapeChanged.Node);
  end;
  if Assigned(FPreviousGeometryChanged)then
    FPreviousGeometryChanged(Scene,LocalGeometryChanged,OnlyShapeChanged);
end;

procedure TRiderLod.ClearBatchDependencies;
var I:Integer;N:TX3DNode;
begin
  for I:=0 to High(FBatchDependencies)do begin
    N:=FBatchDependencies[I].Node;
    if N<>nil then begin
      N.InternalRemoveFieldChangeNotification(@BatchFieldChanged);
      N.RemoveDestructionNotification(@BatchNodeDestroyed);
    end;
  end;
  SetLength(FBatchDependencies,0);
end;

procedure TRiderLod.AddBatchDependency(const Node:TX3DNode;const Batch:Integer);
var I,J,N:Integer;
begin
  if Node=nil then Exit;
  I:=0;
  while(I<Length(FBatchDependencies))and(FBatchDependencies[I].Node<>Node)do Inc(I);
  if I=Length(FBatchDependencies)then begin
    SetLength(FBatchDependencies,I+1);FBatchDependencies[I].Node:=Node;
    Node.InternalAddFieldChangeNotification(@BatchFieldChanged);
    Node.AddDestructionNotification(@BatchNodeDestroyed);
  end;
  if Batch<0 then Exit;
  for J:=0 to High(FBatchDependencies[I].Batches)do
    if FBatchDependencies[I].Batches[J]=Batch then Exit;
  N:=Length(FBatchDependencies[I].Batches);
  SetLength(FBatchDependencies[I].Batches,N+1);FBatchDependencies[I].Batches[N]:=Batch;
end;

procedure TRiderLod.AddGeometryDependency(Node:TX3DNode);
begin AddBatchDependency(Node,FDependencyBatch)end;

procedure TRiderLod.CaptureBatchDependencies;
var I,J,M:Integer;S:TShapeNode;
  procedure CaptureSource(const Source:TShapeNode);
  begin
    if Source=nil then Exit;
    AddBatchDependency(Source,FDependencyBatch);
    if Source.Geometry<>nil then
      Source.Geometry.EnumerateNodes(TX3DNode,@AddGeometryDependency,False);
    { Appearance/effect/material/texture nodes are shared by reference, not
      copied. Their live values therefore apply to both source and batch.
      Replacing source.Appearance itself is caught on the source Shape. }
  end;
begin
  ClearBatchDependencies;
  if Length(FBatches)=0 then Exit;
  AddBatchDependency(FSkin,-1);
  for I:=0 to High(FBatches)do begin
    FDependencyBatch:=I;AddBatchDependency(FBatches[I].Shape,I);
    for J:=0 to 1 do begin
      S:=FBatches[I].Source[J];CaptureSource(S);M:=FindMembership(S);
      { Editing the authored source also invalidates its derived-LOD batch. }
      if M>=0 then CaptureSource(FParts[FMembership[M].Part].Source);
    end;
  end;
end;

procedure TRiderLod.BuildBatches;
var I,J,K,N,LevelA,LevelB:Integer;A,B:TShapeNode;Used:array of Boolean;
  function BodyPart(const Shape:TShapeNode):Boolean;
  begin Result:=(Pos('Body_Lower',Shape.X3DName)>0)or(Pos('Body_Upper',Shape.X3DName)>0)end;
  function LevelOf(const Shape:TShapeNode):Integer;
  var M:Integer;
  begin M:=FindMembership(Shape);if M>=0 then Result:=FMembership[M].Level else Result:=0 end;
begin
  if(FScene=nil)or(FSkin=nil)or(Length(FBatches)>0)or
    (GetEnvironmentVariable('REZVIVO_RIDER_PART_BATCH')<>'1')then Exit;
  if not FFilterAttached then FPrevious:=FScene.OnRenderShapeFilter;
  { Body parts are not culled by the known face filter. Keep every existing
    source callback/side effect once, and never reinterpret an unknown filter. }
  if Assigned(FPrevious)and((TMethod(FPrevious).Data=nil)or
    (TObject(TMethod(FPrevious).Data).ClassName<>'TRiderFace'))then Exit;
  N:=FSkin.FdShapes.Count;SetLength(Used,N);
  Inc(FOwnChangeDepth);
  try
  FScene.BeginChangesSchedule;
  try
    for I:=0 to N-1 do begin
      if Used[I]or not(FSkin.FdShapes[I]is TShapeNode)then Continue;
      A:=TShapeNode(FSkin.FdShapes[I]);if not BodyPart(A)then Continue;LevelA:=LevelOf(A);
      if(A.ParentFieldsCount<>1)or(A.ParentFields[0]<>FSkin.FdShapes)then Continue;
      for J:=I+1 to N-1 do begin
        if Used[J]or not(FSkin.FdShapes[J]is TShapeNode)then Continue;
        B:=TShapeNode(FSkin.FdShapes[J]);if not BodyPart(B)then Continue;LevelB:=LevelOf(B);
        if(B.ParentFieldsCount<>1)or(B.ParentFields[0]<>FSkin.FdShapes)then Continue;
        if(LevelA<>LevelB)or not RiderMergeCompatible(A,B)then Continue;
        K:=Length(FBatches);SetLength(FBatches,K+1);
        FBatches[K].Source[0]:=A;FBatches[K].Source[1]:=B;FBatches[K].Level:=LevelA;
        FBatches[K].Shape:=TShapeNode.Create('RiderPartBatch_'+IntToStr(K));
        RiderMergeGeometry(A,B,FBatches[K].Shape);FBatches[K].Valid:=True;
        FSkin.FdShapes.Add(FBatches[K].Shape);Used[I]:=True;Used[J]:=True;Break;
      end;
    end;
    if(Length(FBatches)>0)and not FFilterAttached then begin
      FScene.OnRenderShapeFilter:=@Filter;FFilterAttached:=True;
    end;
    SetLength(FBatchSelected,Length(FBatches));FSelectionValid:=False;
    { MFNode.Add only edits the raw list. Publish all appended shapes once,
      before the filter suppresses their sources in the renderer's tree.
      Keep this owned structural change out of the external-edit fallback. }
    if Length(FBatches)>0 then FSkin.FdShapes.Changed;
  finally FScene.EndChangesSchedule end;
  finally Dec(FOwnChangeDepth)end;
  CaptureBatchDependencies;
  if(Length(FBatches)>0)and not FGeometryObserverAttached then begin
    FPreviousGeometryChanged:=FScene.OnGeometryChanged;
    FScene.OnGeometryChanged:=@BatchGeometryChanged;FGeometryObserverAttached:=True;
  end;
end;

procedure TRiderLod.RefreshSelection;
var L,I,J,M:Integer;Revision:QWord;Allowed:Boolean;
begin
  L:=FLevel;if RiderLodOverride>=0 then L:=EnsureRange(RiderLodOverride,0,2);
  { Models without an authored LOD retain level zero. }
  if Length(FParts)=0 then L:=0;
  Revision:=FScene.InternalSnapshotRevision;
  if FSelectionValid and(FSelectionRevision=Revision)and(FSelectionLevel=L)then Exit;
  { Scene revision covers visibility/material/geometry edits, including direct
    editor changes. Effect uniform updates intentionally do not invalidate it.
    We cache only pure membership, never previous filter callbacks or results. }
  for I:=0 to High(FMembership)do FSelected[I]:=FMembership[I].Alive and
    (FMembership[I].Level=L)and(FParts[FMembership[I].Part].Source<>nil)and
    FParts[FMembership[I].Part].Source.Visible;
  for I:=0 to High(FBatches)do begin
    with FBatches[I]do Allowed:=FBatchActive and Valid and(Level=L)and
      (Source[0]<>nil)and(Source[1]<>nil)and(Shape<>nil)and
      Source[0].Visible and Source[1].Visible and
      (Source[0].Appearance=Shape.Appearance)and(Source[1].Appearance=Shape.Appearance);
    { Wardrobe toggles authored parts, not their derived LOD nodes. }
    if Allowed then for J:=0 to 1 do begin
      M:=FindMembership(FBatches[I].Source[J]);
      if(M>=0)and not FSelected[M]then Allowed:=False;
    end;
    FBatchSelected[I]:=Allowed;
  end;
  FSelectionRevision:=Revision;FSelectionLevel:=L;FSelectionValid:=True;
end;

function TRiderLod.BatchAllowed(const Index:Integer):Boolean;
begin
  RefreshSelection;Result:=FBatchSelected[Index];
end;
function TRiderLod.SuppressedByBatch(const Shape:TAbstractShapeNode):Boolean;
var I:Integer;
begin
  Result:=False;if not FBatchActive then Exit;
  for I:=0 to High(FBatches)do if((Shape=FBatches[I].Source[0])or(Shape=FBatches[I].Source[1]))and
    BatchAllowed(I)then Exit(True);
end;

procedure TRiderLod.Update;
var I,K:Integer;Rebuilt:Boolean;Retired:array of TAbstractGeometryNode;
begin
  if not FDirty then Exit;FDirty:=False;FSelectionValid:=False;
  SetLength(Retired,Length(FBatches));Rebuilt:=False;
  Inc(FOwnChangeDepth);
  try
    FScene.BeginChangesSchedule;
    try
      for I:=0 to High(FParts)do if FParts[I].Source<>nil then
        for K:=1 to 2 do if FParts[I].Shapes[K]<>nil then CopyVertices(FParts[I],K,False);
      for I:=0 to High(FBatches)do begin
        FBatches[I].Valid:=BatchParentsCompatible(I)and
          RiderMergeCompatible(FBatches[I].Source[0],FBatches[I].Source[1]);
        if FBatches[I].Valid then begin
          { Shape.Geometry.Send is only chVisibleNonGeometry in CGE. The
            current TShape retains its old Geometry until ChangedAll. Keep
            that node alive across the swap and rebuild once for all batches,
            rather than leave dangling geometry in render/association caches. }
          Retired[I]:=FBatches[I].Shape.Geometry;
          if Retired[I]<>nil then Retired[I].KeepExistingBegin;
          RiderMergeGeometry(FBatches[I].Source[0],FBatches[I].Source[1],FBatches[I].Shape);
          Rebuilt:=True;
        end;
      end;
    finally FScene.EndChangesSchedule end;
    if Rebuilt then FScene.ChangedAll;
  finally
    Dec(FOwnChangeDepth);
    for I:=0 to High(Retired)do if Retired[I]<>nil then begin
      Retired[I].KeepExistingEnd;Retired[I].FreeIfUnused;
    end;
  end;
  CaptureBatchDependencies;
end;

function TRiderLod.Filter(const Shape:TAbstractShapeNode;const Params:TRenderParams):Boolean;
var I,K,Level:Integer;Source:TAbstractShapeNode;M:TMatrix4;A,B:TVector4;
  HeightPixels:Single;
begin
  { A collector is free to visit a batch before its source parts. Decide the
    level once before either path, never inherit last frame's batch level. }
  if(Length(FParts)>0)and(Params.RenderingCamera.Target=rtScreen)and
    (FProjectionFrame<>TFramesPerSecond.RenderFrameId)then begin
    FProjectionFrame:=TFramesPerSecond.RenderFrameId;
    M:=Params.RenderingCamera.Matrix*Params.Transformation^.Transform;
    A:=M*Vector4(0,0.1,0,1);B:=M*Vector4(0,1.9,0,1);FDistance:=Max(0.1,Abs((A.Z+B.Z)*0.5));
    HeightPixels:=1.8*0.5*Abs(Params.RenderingCamera.Projection.Data[1,1])*
      RenderContext.Viewport.Height/FDistance;
    FPixels:=HeightPixels;
    case FLevel of
      0:if HeightPixels<65 then FLevel:=2 else if HeightPixels<150 then FLevel:=1;
      1:if HeightPixels>172 then FLevel:=0 else if HeightPixels<65 then FLevel:=2;
      2:if HeightPixels>172 then FLevel:=0 else if HeightPixels>75 then FLevel:=1;
    end;
  end;
  for I:=0 to High(FBatches)do if Shape=FBatches[I].Shape then Exit(BatchAllowed(I));
  Source:=Shape;Level:=-1;
  if FUseMembership then begin
    I:=FindMembership(Shape);
    if I>=0 then begin
      RefreshSelection;if not FSelected[I]then Exit(False);
      Level:=FMembership[I].Level;Source:=FParts[FMembership[I].Part].Source;
    end;
  end else for I:=0 to High(FParts)do begin
    if Shape=FParts[I].Source then begin Level:=0;Break end;
    for K:=1 to 2 do if Shape=FParts[I].Shapes[K]then begin Source:=FParts[I].Source;Level:=K;Break end;
    if Level>=0 then Break;
  end;
  if Level<0 then begin
    Result:=True;if Assigned(FPrevious)then Result:=FPrevious(Source,Params);
    if Result then Result:=not SuppressedByBatch(Shape);Exit;
  end;
  if(Source=nil)or not TShapeNode(Source).Visible then Exit(False);
  if RiderLodOverride>=0 then K:=EnsureRange(RiderLodOverride,0,2)else K:=FLevel;
  Result:=Level=K;
  if Result and Assigned(FPrevious)then Result:=FPrevious(Source,Params);
  if Result then Result:=not SuppressedByBatch(Shape);
end;

function TRiderLod.DebugJson:TJSONObject;
var I,ValidBatches,SelectedBatches:Integer;A:TJSONArray;O:TJSONObject;
begin
  if FScene<>nil then RefreshSelection;
  ValidBatches:=0;SelectedBatches:=0;
  for I:=0 to High(FBatches)do begin
    if FBatches[I].Valid then Inc(ValidBatches);
    if FBatchSelected[I]then Inc(SelectedBatches);
  end;
  Result:=TJSONObject.Create;Result.Add('parts',Length(FParts));Result.Add('auto_level',FLevel);
  Result.Add('membership',FUseMembership);
  Result.Add('batches',Length(FBatches));Result.Add('batch_active',FBatchActive);
  Result.Add('valid_batches',ValidBatches);Result.Add('selected_batches',SelectedBatches);
  Result.Add('override',RiderLodOverride);Result.Add('pixels',FPixels);Result.Add('distance',FDistance);
  A:=TJSONArray.Create;Result.Add('levels',A);
  for I:=0 to 2 do begin O:=TJSONObject.Create;O.Add('vertices',FVertices[I]);
    O.Add('triangles',FTriangles[I]);A.Add(O)end;
end;
end.
