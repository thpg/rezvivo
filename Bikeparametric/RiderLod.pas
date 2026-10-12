unit RiderLod;
{$mode objfpc}{$H+}
{ Offline topology maps, one shared rig/material set. Compact vertex buffers
  also reduce transform-feedback skinning work. No model reload at transitions. }
interface
uses Classes,SysUtils,Math,fpjson,CastleVectors,CastleScene,CastleRenderOptions,
  CastleRenderContext,CastleTransform,CastleTimeUtils,X3DNodes,X3DFields;
type
  TRiderLod=class
  private
    type
      TPart=record
        Source:TShapeNode;
        Shapes:array[1..2]of TShapeNode;
        Maps:array[1..2]of array of Cardinal;
      end;
    var
      FScene:TCastleScene;
      FSkin:TSkinNode;
      FParts:array of TPart;
      FPrevious:TRenderShapeFilter;
      FLevel:Integer;
      FPixels,FDistance:Single;
      FDirty:Boolean;
      FAttached:Boolean;
      FProjectionFrame:TFrameId;
      FTriangles,FVertices:array[0..2]of Integer;
    function Filter(const Shape:TAbstractShapeNode;const Params:TRenderParams):Boolean;
    procedure CopyVertices(var P:TPart;Level:Integer;CreateNodes:Boolean);
  public
    constructor Create(Scene:TCastleScene;Skin:TSkinNode;const Path:string);
    destructor Destroy;override;
    procedure Invalidate;
    procedure Update;
    function DebugJson:TJSONObject;
  end;
var
  RiderLodOverride:Integer=-1; { -1 automatic, 0 full, 1 medium, 2 far; diagnostics }
implementation
uses GltfCore,RiderCorrectiveData;

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
    FPrevious:=Scene.OnRenderShapeFilter;Scene.OnRenderShapeFilter:=@Filter;
  finally Info.Free;Data.Free end;
end;

destructor TRiderLod.Destroy;
var I,K:Integer;
begin
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
procedure TRiderLod.Update;
var I,K:Integer;
begin
  if not FDirty then Exit;FDirty:=False;
  FScene.BeginChangesSchedule;
  try for I:=0 to High(FParts)do for K:=1 to 2 do CopyVertices(FParts[I],K,False);
  finally FScene.EndChangesSchedule end;
end;

function TRiderLod.Filter(const Shape:TAbstractShapeNode;const Params:TRenderParams):Boolean;
var I,K,Level:Integer;Source:TAbstractShapeNode;M:TMatrix4;A,B:TVector4;
  HeightPixels:Single;
begin
  Source:=Shape;Level:=-1;
  for I:=0 to High(FParts)do begin
    if Shape=FParts[I].Source then begin Level:=0;Break end;
    for K:=1 to 2 do if Shape=FParts[I].Shapes[K]then begin Source:=FParts[I].Source;Level:=K;Break end;
    if Level>=0 then Break;
  end;
  if Level<0 then begin
    Result:=True;if Assigned(FPrevious)then Result:=FPrevious(Source,Params);Exit;
  end;
  if not TShapeNode(Source).Visible then Exit(False);
  if(Params.RenderingCamera.Target=rtScreen)and
    (FProjectionFrame<>TFramesPerSecond.RenderFrameId)then begin
    FProjectionFrame:=TFramesPerSecond.RenderFrameId;
    M:=Params.RenderingCamera.Matrix*Params.Transformation^.Transform;
    A:=M*Vector4(0,0.1,0,1);B:=M*Vector4(0,1.9,0,1);FDistance:=Max(0.1,Abs((A.Z+B.Z)*0.5));
    HeightPixels:=1.8*0.5*Abs(Params.RenderingCamera.Projection.Data[1,1])*
      RenderContext.Viewport.Height/FDistance;
    FPixels:=HeightPixels;
    { Hysteresis: avoid chatter near a boundary and keep normal chase view full. }
    case FLevel of
      0:if HeightPixels<65 then FLevel:=2 else if HeightPixels<150 then FLevel:=1;
      1:if HeightPixels>172 then FLevel:=0 else if HeightPixels<65 then FLevel:=2;
      2:if HeightPixels>172 then FLevel:=0 else if HeightPixels>75 then FLevel:=1;
    end;
  end;
  if RiderLodOverride>=0 then K:=EnsureRange(RiderLodOverride,0,2)else K:=FLevel;
  Result:=Level=K;
  if Result and Assigned(FPrevious)then Result:=FPrevious(Source,Params);
end;

function TRiderLod.DebugJson:TJSONObject;
var I:Integer;A:TJSONArray;O:TJSONObject;
begin
  Result:=TJSONObject.Create;Result.Add('parts',Length(FParts));Result.Add('auto_level',FLevel);
  Result.Add('override',RiderLodOverride);Result.Add('pixels',FPixels);Result.Add('distance',FDistance);
  A:=TJSONArray.Create;Result.Add('levels',A);
  for I:=0 to 2 do begin O:=TJSONObject.Create;O.Add('vertices',FVertices[I]);
    O.Add('triangles',FTriangles[I]);A.Add(O)end;
end;
end.
