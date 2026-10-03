unit RiderHair;
{$mode objfpc}{$H+}
interface
uses X3DNodes, X3DFields, CastleVectors, CastleScene, CastleTransform,
  RiderHairData, RiderHairPhysics, fpjson;
type
  TRiderWindSampler=function(const WorldPosition:TVector3):TVector3;
  TRiderHairStyle = (rhsBald,rhsShort,rhsSwept,rhsCurly,rhsPonytail,
    rhsBuzz,rhsParted,rhsCoils,rhsMedium,rhsBraid,rhsLongBraid,rhsDoubleBraids,rhsDreadlocks);
  TRiderHair = class
  private
    FRoot:TMatrixTransformNode;
    FParent:TAbstractGroupingNode;
    FCap:TShapeNode;
    FScalps:array[0..HairLodCount-1]of TShapeNode;
    FScalpGroup:TGroupNode;
    FScene:TCastleScene;
    FPreviousFilter:TRenderShapeFilter;
    FBundlesAppearance:TAppearanceNode;
    FChoices:TSwitchNode;
    FLods:array[TRiderHairStyle]of TGroupNode;
    FEffect:TEffectNode;
    FStyle:TRiderHairStyle;
    FColor:TVector3;
    FColorField:TSFVec3f;
    FPointsField:TMFVec3f;
    FPoints:TVector3List;
    FDetailField:TSFFloat;
    FStyleField:TSFFloat;
    FHelmetField:TSFFloat;
    FCoveredField:TSFFloat;
    FHead:TVector3;
    FScale:Single;
    FHelmet,FScalpAttached:Boolean;
    FMaskPath:String;
    FData:TRiderHairData;
    FPhysics:TRiderHairPhysics;
    FLod:Integer;
    FShadowLod:Integer;
    FScreenPixels,FShadowPixels:Single;
    FDetail,FTickAccum:Single;
    procedure AttachScalp(Node:TX3DNode);
    procedure EnsureStyle(Value:TRiderHairStyle);
    procedure SetStyle(Value:TRiderHairStyle);
    procedure SetColor(const Value:TVector3);
    procedure SetHelmet(Value:Boolean);
    procedure SetCovered(Value:Boolean);
    procedure SendPhysics;
    function FilterShape(const Shape:TAbstractShapeNode;const Params:TRenderParams):Boolean;
    function LodTriangleCount(Lod:Integer):Integer;
  public
    constructor Create(Parent:TAbstractGroupingNode;const Head:TVector3;
      const Scale:Single;Helmet:Boolean);
    destructor Destroy; override;
    procedure Follow(const Matrix:TMatrix4);
    procedure InstallScalp(Root:TX3DNode;const MaskPath:String);
    procedure BindScene(Scene:TCastleScene);
    procedure Update(Scene:TCastleScene;Dt,Speed:Single);
    procedure SetTorso(Scene:TCastleScene;const A,B:TVector3;Radius:Single);
    function CaptureReplay:THairMotionState;
    procedure RestoreReplay(const Value:THairMotionState);
    procedure DebugJson(Result:TJSONObject);
    function TriangleCount:Integer;
    property Root:TMatrixTransformNode read FRoot;
    property Style:TRiderHairStyle read FStyle write SetStyle;
    property Color:TVector3 read FColor write SetColor;
    property Helmet:Boolean read FHelmet write SetHelmet;
    property Covered:Boolean write SetCovered;
  end;
const SelectableHairStyles:array[0..8]of TRiderHairStyle=(rhsBald,rhsShort,rhsCurly,
  rhsMedium,rhsPonytail,rhsBraid,rhsLongBraid,rhsDoubleBraids,rhsDreadlocks);
function CanonicalHairStyle(Style:TRiderHairStyle):TRiderHairStyle;
function RiderHairStyleId(Style:TRiderHairStyle):String;
function RiderHairStyleCaption(Style:TRiderHairStyle):String;
function ParseRiderHairStyle(const Id:String):TRiderHairStyle;
{ World-space ambient air velocity, metres/sec; motion-relative wind is added
  per rider. A scene may set this to its shared wind field. }
var RiderWindWorld:TVector3=(X:1.2;Y:0;Z:0.35);
    RiderWindSampler:TRiderWindSampler=nil;
    RiderHairQuality:Integer=2;
    { Explicit MCP isolation probes; normal rendering leaves all enabled. }
    RiderHairProbePhysics:Boolean=True;
    RiderHairProbeUpload:Boolean=True;
    RiderHairProbeFollow:Boolean=True;
    RiderHairProbeCoverage:Boolean=True;
implementation
uses SysUtils,Math,CastleRenderOptions,CastleRenderContext,RiderHairMaterial;
type
  TRiderHairShape=class(TShapeNode)
  public
    Hair:TRiderHair;
    Lod:Integer;
  end;
const
  HairIds:array[TRiderHairStyle]of String=('bald','short','swept','curly','ponytail',
    'buzz','parted','coils','medium','braid','long_braid','double_braids','dreadlocks');
  HairCaptions:array[TRiderHairStyle]of String=('No hair','Short crop','Swept back','Curly hair','Ponytail',
    'Buzz cut','Side part','Tight curls','Medium length','Braid','Long braid','Two braids','Dreadlocks');
function CanonicalHairStyle(Style:TRiderHairStyle):TRiderHairStyle;
begin
  case Style of rhsBuzz,rhsParted,rhsSwept:Result:=rhsShort;
    rhsCoils:Result:=rhsCurly;else Result:=Style end;
end;
function RiderHairStyleId(Style:TRiderHairStyle):String;
begin Result:=HairIds[Style] end;
function RiderHairStyleCaption(Style:TRiderHairStyle):String;
begin Result:=HairCaptions[Style] end;
function ParseRiderHairStyle(const Id:String):TRiderHairStyle;
var S:TRiderHairStyle;
begin
  if SameText(Trim(Id),'original')then Exit(rhsBald);
  for S:=Low(S)to High(S)do if SameText(Trim(Id),HairIds[S])then Exit(CanonicalHairStyle(S));
  Result:=rhsShort;
end;
constructor TRiderHair.Create(Parent:TAbstractGroupingNode;const Head:TVector3;
  const Scale:Single;Helmet:Boolean);
var V,F:TEffectPartNode;I:Integer;
begin
  inherited Create;FHead:=Head;FScale:=Scale;FHelmet:=Helmet;FParent:=Parent;
  FRoot:=TMatrixTransformNode.Create('RiderProceduralHair');
  FEffect:=TEffectNode.Create('RiderHairScattering');FEffect.Language:=slGLSL;FEffect.UniformMissing:=umIgnore;
  FColorField:=TSFVec3f.Create(FEffect,True,'rhColor',Vector3(0.055,0.024,0.011));
  FEffect.AddCustomField(FColorField);
  FHelmetField:=TSFFloat.Create(FEffect,True,'rhHelmet',Ord(Helmet));
  FEffect.AddCustomField(FHelmetField);
  FCoveredField:=TSFFloat.Create(FEffect,True,'rhClothHat',0);FEffect.AddCustomField(FCoveredField);
  FStyleField:=TSFFloat.Create(FEffect,True,'rhStyle',Ord(rhsShort));FEffect.AddCustomField(FStyleField);
  FDetailField:=TSFFloat.Create(FEffect,True,'rhDetail',1);FEffect.AddCustomField(FDetailField);FDetail:=1;
  FPointsField:=TMFVec3f.Create(FEffect,True,'rhGuides',[]);
  FPoints:=TVector3List.Create;
  for I:=0 to HairPointCount-1 do FPoints.Add(TVector3.Zero);
  FPointsField.Items.Assign(FPoints);FEffect.AddCustomField(FPointsField);
  V:=TEffectPartNode.Create;V.ShaderType:=stVertex;V.Contents:=RiderHairVertexShader;
  F:=TEffectPartNode.Create;F.ShaderType:=stFragment;F.Contents:=RiderHairFragmentShader;FEffect.SetParts([V,F]);
  FCap:=TShapeNode.Create('RiderHairScalp');FRoot.AddChildren(FCap);
  FChoices:=TSwitchNode.Create('RiderHairStyles');FRoot.AddChildren(FChoices);
  FPhysics:=TRiderHairPhysics.Create;FStyle:=rhsShort;
  SetColor(Vector3(0.26,0.17,0.105));Follow(TMatrix4.Identity);
end;
destructor TRiderHair.Destroy;
begin
  if(FScene<>nil)and(TMethod(FScene.OnRenderShapeFilter).Data=Pointer(Self))then
    FScene.OnRenderShapeFilter:=FPreviousFilter;
  FPoints.Free;FPhysics.Free;
  { The scene owns its geometry, materials and effects. The process cache owns
    only packed, immutable vertices and guides, never scene-bound nodes. }
  inherited;
end;
procedure TRiderHair.InstallScalp(Root:TX3DNode;const MaskPath:String);
var Path,Stem:String;Tex:TImageTextureNode;
  S:TRiderHairStyle;I:Integer;TextureField:TSFNode;Sh:TRiderHairShape;
begin
  FMaskPath:=MaskPath;
  Stem:=ChangeFileExt(ExtractFileName(MaskPath),'');
  I:=Pos('-scalp',Stem);if I>0 then Stem:=Copy(Stem,1,I-1);
  Path:=ExtractFilePath(MaskPath)+Stem+'-groom.hair';
  FData:=LoadRiderHairData(Path);
  if FData<>nil then begin
    Tex:=TImageTextureNode.Create('RiderHairAtlas');Tex.SetUrl([ExtractFilePath(MaskPath)+'strands.png']);
    Tex.RepeatS:=False;Tex.RepeatT:=False;
    TextureField:=TSFNode.Create(FEffect,True,'rhAtlas',[TImageTextureNode]);
    TextureField.Value:=Tex;FEffect.AddCustomField(TextureField);
    for S:=Low(S)to High(S)do begin
      FLods[S]:=TGroupNode.Create('RiderHair_'+HairIds[S]);FChoices.AddChildren(FLods[S]);
      EnsureStyle(S);
    end;
    if Length(FData.Scalp[0].Indices)>0 then begin
      FScalpGroup:=TGroupNode.Create('RiderHairScalps');FRoot.AddChildren(FScalpGroup);
      for I:=0 to HairLodCount-1 do begin
        Sh:=TRiderHairShape.Create('RiderHairScalp_'+IntToStr(I));
        Sh.Hair:=Self;Sh.Lod:=I;Sh.Appearance:=FBundlesAppearance;
        Sh.Geometry:=FData.ScalpGeometry(I);FScalps[I]:=Sh;FScalpGroup.AddChildren(Sh);
      end;
    end;
  end;
  { Compatibility with the earlier three-LOD groom format. }
  if(FScalpGroup=nil)and FileExists(FMaskPath)then
    Root.EnumerateNodes(TShapeNode,@AttachScalp,False);
  SetStyle(FStyle);
  { No partially built geometry may be published to a live scene. }
  FParent.AddChildren(FRoot);
end;
procedure TRiderHair.EnsureStyle(Value:TRiderHairStyle);
var I,J:Integer;Sh:TRiderHairShape;App:TAppearanceNode;Mat:TPhysicalMaterialNode;
  Shapes:array[0..HairLodCount-1]of TShapeNode;
begin
  if(FData=nil)or(FLods[Value]=nil)or(FLods[Value].FdChildren.Count>0)then Exit;
  I:=FData.IndexOf(HairIds[Value]);if I<0 then Exit;
  { All styles use the same material and uniforms. Separate appearances would
    keep redundant shader listeners alive after switching hairstyles. }
  if FBundlesAppearance=nil then begin
    FBundlesAppearance:=TAppearanceNode.Create('RiderHairBundles');
    Mat:=TPhysicalMaterialNode.Create;Mat.BaseColor:=Vector3(1,1,1);Mat.Metallic:=0;Mat.Roughness:=0.67;
    FBundlesAppearance.Material:=Mat;FBundlesAppearance.AlphaMode:=amMask;
    FBundlesAppearance.AlphaCutoff:=0.12;FBundlesAppearance.AlphaToCoverage:=True;
    FBundlesAppearance.FdEffects.Add(FEffect);
  end;
  App:=FBundlesAppearance;
  for J:=0 to HairLodCount-1 do begin
    Sh:=TRiderHairShape.Create('RiderHair_'+HairIds[Value]+'_'+IntToStr(J));
    Sh.Hair:=Self;Sh.Lod:=J;
    Sh.Appearance:=App;Sh.Geometry:=FData.Geometry(I,J);Shapes[J]:=Sh;
  end;
  { Build all choices before publishing the graph. Adding geometry later would
    invalidate the renderer's skin bindings while a paused pose is displayed. }
  for J:=0 to HairLodCount-1 do FLods[Value].AddChildren(Shapes[J]);
end;
procedure TRiderHair.AttachScalp(Node:TX3DNode);
var Sh:TShapeNode;App,HairApp:TAppearanceNode;Geo,CapGeo:TIndexedTriangleSetNode;
  Coord,CapCoord:TCoordinateNode;Normals,CapNormals:TNormalNode;UV,CapUV:TTextureCoordinateNode;
  UVNode:TX3DNode;B,R,G,T,H,U:TFloatVertexAttributeNode;
  P,N,Flow:TVector3;I,J:Integer;Nm:String;
  HairMat:TPhysicalMaterialNode;Used:array of Boolean;Map:array of Integer;
  function Attr(const Name:String;Size:Integer):TFloatVertexAttributeNode;
  begin
    Result:=TFloatVertexAttributeNode.Create;Result.NameField:=Name;Result.NumComponents:=Size;
    CapGeo.FdAttrib.Add(Result);
  end;
  procedure Vec(A:TFloatVertexAttributeNode;const P:TVector3);
  begin A.FdValue.Items.Add(P.X);A.FdValue.Items.Add(P.Y);A.FdValue.Items.Add(P.Z) end;
  function KeepTriangle(A,B,C:Integer):Boolean;
  begin
    { Hairline coverage is evaluated per fragment. A few samples of a coarse
      head triangle are not a conservative test of its UV footprint. }
    Result:=Max(Coord.FdPoint.Items[A].Y,Max(Coord.FdPoint.Items[B].Y,Coord.FdPoint.Items[C].Y))>FHead.Y-0.055*FScale;
  end;
begin
  Sh:=TShapeNode(Node);
  if FScalpAttached or not(Sh.Appearance is TAppearanceNode)or not(Sh.Geometry is TIndexedTriangleSetNode)then Exit;
  App:=TAppearanceNode(Sh.Appearance);if not(App.Material is TPhysicalMaterialNode)then Exit;
  Nm:=LowerCase(App.X3DName+' '+App.Material.X3DName);if Pos('portrait',Nm)=0 then Exit;
  Geo:=TIndexedTriangleSetNode(Sh.Geometry);UVNode:=Geo.TexCoord;
  if(UVNode is TMultiTextureCoordinateNode)and(TMultiTextureCoordinateNode(UVNode).FdTexCoord.Count>0)then
    UVNode:=TMultiTextureCoordinateNode(UVNode).FdTexCoord[0];
  if not(Geo.Coord is TCoordinateNode)or not(Geo.Normal is TNormalNode)or not(UVNode is TTextureCoordinateNode)then Exit;
  Coord:=TCoordinateNode(Geo.Coord);Normals:=TNormalNode(Geo.Normal);UV:=TTextureCoordinateNode(UVNode);
  if(Normals.FdVector.Count<>Coord.FdPoint.Count)or(UV.FdPoint.Count<>Coord.FdPoint.Count)then Exit;
  CapGeo:=TIndexedTriangleSetNode.Create;CapGeo.Solid:=False;
  CapCoord:=TCoordinateNode.Create;CapNormals:=TNormalNode.Create;CapUV:=TTextureCoordinateNode.Create;
  CapGeo.Coord:=CapCoord;CapGeo.Normal:=CapNormals;CapGeo.TexCoord:=CapUV;
  B:=Attr('riderHairBind',4);R:=Attr('riderHairRest',3);G:=Attr('riderHairGuide',3);
  T:=Attr('riderHairStrand',3);H:=Attr('riderHairHelmet',3);
  U:=Attr('riderHairUV',2);
  SetLength(Used,Coord.FdPoint.Count);SetLength(Map,Coord.FdPoint.Count);
  for I:=0 to Geo.FdIndex.Count div 3-1 do
    if KeepTriangle(Geo.FdIndex.Items[I*3],Geo.FdIndex.Items[I*3+1],Geo.FdIndex.Items[I*3+2])then
      for J:=0 to 2 do Used[Geo.FdIndex.Items[I*3+J]]:=True;
  for I:=0 to Coord.FdPoint.Count-1 do if Used[I]then begin
    Map[I]:=CapCoord.FdPoint.Count;P:=(Coord.FdPoint.Items[I]-FHead)*(1/FScale);N:=Normals.FdVector.Items[I];
    CapCoord.FdPoint.Items.Add(P+N*0.0012);CapNormals.FdVector.Items.Add(N);CapUV.FdPoint.Items.Add(UV.FdPoint.Items[I]);
    Flow:=Vector3(0,-1,0)+N*N.Y;
    if Flow.LengthSqr<0.001 then Flow:=Vector3(0,0,-1);Flow:=Flow.Normalize;
    B.FdValue.Items.Add(-1);B.FdValue.Items.Add(0);B.FdValue.Items.Add(0);B.FdValue.Items.Add(0);
    Vec(R,P);Vec(G,Flow);Vec(T,Flow);Vec(H,TVector3.Zero);
    U.FdValue.Items.Add(UV.FdPoint.Items[I].X);U.FdValue.Items.Add(UV.FdPoint.Items[I].Y);
  end;
  for I:=0 to Geo.FdIndex.Count div 3-1 do
    if KeepTriangle(Geo.FdIndex.Items[I*3],Geo.FdIndex.Items[I*3+1],Geo.FdIndex.Items[I*3+2])then
      for J:=0 to 2 do CapGeo.FdIndex.Items.Add(Map[Geo.FdIndex.Items[I*3+J]]);
  HairApp:=TAppearanceNode.Create('RiderHairScalpMaterial');HairMat:=TPhysicalMaterialNode.Create;
  HairMat.BaseColor:=Vector3(1,1,1);HairMat.Metallic:=0;HairMat.Roughness:=0.67;
  HairApp.Material:=HairMat;HairApp.FdEffects.Add(FEffect);FCap.Appearance:=HairApp;FCap.Geometry:=CapGeo;
  FScalpAttached:=True;
end;
function TRiderHair.LodTriangleCount(Lod:Integer):Integer;
var I:Integer;
begin
  Result:=0;if FStyle=rhsBald then Exit;
  if FScalps[Lod]<>nil then
    Result:=TIndexedTriangleSetNode(FScalps[Lod].Geometry).FdIndex.Count div 3
  else if FCap.Geometry is TIndexedTriangleSetNode then
    Result:=TIndexedTriangleSetNode(FCap.Geometry).FdIndex.Count div 3;
  if FData<>nil then begin I:=FData.IndexOf(HairIds[FStyle]);if I>=0 then Inc(Result,Length(FData.Styles[I].Mesh[Lod].Indices)div 3) end;
end;
function TRiderHair.TriangleCount:Integer;
begin Result:=LodTriangleCount(FLod) end;

function ChooseLod(const Pixels:Single;Previous:Integer):Integer;
begin
  Result:=EnsureRange(Previous,0,HairLodCount-1);
  while(Result<3)do begin
    if((Result=0)and(Pixels>=125))or((Result=1)and(Pixels>=40))or
      ((Result=2)and(Pixels>=12))then Break;
    Inc(Result);
  end;
  while(Result>0)do begin
    if((Result=1)and(Pixels<=165))or((Result=2)and(Pixels<=55))or
      ((Result=3)and(Pixels<=18))then Break;
    Dec(Result);
  end;
end;

procedure TRiderHair.BindScene(Scene:TCastleScene);
begin
  if FScene=Scene then Exit;
  if(FScene<>nil)and(TMethod(FScene.OnRenderShapeFilter).Data=Pointer(Self))then
    FScene.OnRenderShapeFilter:=FPreviousFilter;
  FScene:=Scene;FPreviousFilter:=nil;
  if FScene<>nil then begin
    FPreviousFilter:=FScene.OnRenderShapeFilter;FScene.OnRenderShapeFilter:=@FilterShape;
  end;
end;

function TRiderHair.FilterShape(const Shape:TAbstractShapeNode;const Params:TRenderParams):Boolean;
const QualityScale:array[0..3]of Single=(0.40,0.65,1.0,1.5);
var M:TMatrix4;P:TVector3;Clip:TVector4;Pixels,Scale:Single;Lod,Quality:Integer;
begin
  Result:=True;
  if Assigned(FPreviousFilter)then Result:=FPreviousFilter(Shape,Params);
  if not Result or not(Shape is TRiderHairShape)then Exit;
  if TRiderHairShape(Shape).Hair<>Self then Exit;
  if FStyle=rhsBald then Exit(False);
  M:=Params.Transformation^.Transform*FRoot.Matrix;
  Scale:=Max(M.MultDirection(Vector3(1,0,0)).Length,
    Max(M.MultDirection(Vector3(0,1,0)).Length,M.MultDirection(Vector3(0,0,1)).Length));
  P:=Params.RenderingCamera.Matrix.MultPoint(M.MultPoint(Vector3(0,0.04,-0.02)));
  Clip:=Params.RenderingCamera.Projection*Vector4(P.X,P.Y,P.Z,1);
  Pixels:=0.25*Scale*0.5*Max(
    Abs(Params.RenderingCamera.Projection.Data[0,0])*RenderContext.Viewport.Width,
    Abs(Params.RenderingCamera.Projection.Data[1,1])*RenderContext.Viewport.Height)/Max(Abs(Clip.W),0.1);
  if Params.RenderingCamera.Target in [rtShadowMap,rtVarianceShadowMap]then begin
    { No view-camera quality bias: only the footprint in the actual shadow
      tile matters. Stateless thresholds work across different atlas zones. }
    if Pixels>=160 then Lod:=0 else if Pixels>=50 then Lod:=1
    else if Pixels>=15 then Lod:=2 else Lod:=3;
    FShadowLod:=Lod;FShadowPixels:=Pixels;
  end else begin
    Quality:=EnsureRange(RiderHairQuality,0,3);
    FScreenPixels:=Pixels;Lod:=ChooseLod(Pixels*QualityScale[Quality],FLod);
    if Quality=0 then Lod:=Max(1,Lod);
    FLod:=Lod;
  end;
  Result:=TRiderHairShape(Shape).Lod=Lod;
end;
procedure TRiderHair.Follow(const Matrix:TMatrix4);
begin
  if not RiderHairProbeFollow then Exit;
  FRoot.Matrix:=Matrix*TranslationMatrix(FHead)*ScalingMatrix(Vector3(FScale,FScale,FScale));
end;
procedure TRiderHair.SendPhysics;
var I:Integer;
begin
  if not RiderHairProbeUpload then Exit;
  for I:=0 to HairPointCount-1 do FPoints[I]:=FPhysics.RenderPoint(I);
  FPointsField.Send(FPoints);
end;
procedure TRiderHair.SetStyle(Value:TRiderHairStyle);
var I:Integer;
begin
  Value:=CanonicalHairStyle(Value);
  if(FStyle=Value)and(FChoices.WhichChoice=Ord(Value))and FPhysics.State.Valid then Exit;
  if not(Value in [rhsLongBraid,rhsDoubleBraids,rhsDreadlocks])then
    FPhysics.SetTorso(TVector3.Zero,TVector3.Zero,0);
  FStyle:=Value;FCap.Visible:=Value<>rhsBald;FChoices.WhichChoice:=Ord(Value);
  if FScalpGroup<>nil then FScalpGroup.Visible:=Value<>rhsBald;
  FStyleField.Send(Ord(Value));
  FTickAccum:=0;
  if FData<>nil then begin
    I:=FData.IndexOf(HairIds[Value]);
    if I>=0 then begin FPhysics.SetGuides(FData.Styles[I].Guides,FHelmet);SendPhysics end;
  end;
end;
procedure TRiderHair.SetHelmet(Value:Boolean);
var I:Integer;
begin
  if FHelmet=Value then Exit;
  FHelmet:=Value;FHelmetField.Send(Ord(Value));FTickAccum:=0;
  if FData<>nil then begin
    I:=FData.IndexOf(HairIds[FStyle]);
    if I>=0 then begin FPhysics.SetGuides(FData.Styles[I].Guides,FHelmet);SendPhysics end;
  end;
end;
procedure TRiderHair.SetCovered(Value:Boolean);
begin
  FCoveredField.Send(Ord(Value));
end;
procedure TRiderHair.SetColor(const Value:TVector3);
var Linear:TVector3;I:Integer;C:Single;
begin
  FColor:=Value;
  for I:=0 to 2 do begin
    C:=EnsureRange(Value.Data[I],0,1);
    if C<=0.04045 then Linear.Data[I]:=C/12.92 else Linear.Data[I]:=Power((C+0.055)/1.055,2.4);
  end;
  FColorField.Send(Linear);
end;
procedure TRiderHair.Update(Scene:TCastleScene;Dt,Speed:Single);
const QualityScale:array[0..3]of Single=(0.40,0.65,1.0,1.5);
var Frame,WorldFrame,WorldInverse,ToParent:TMatrix4;Wind,Gravity,Forward:TVector3;
  Pixels,NewDetail:Single;Quality:Integer;
begin
  if(FData=nil)or(FStyle=rhsBald)or(Scene=nil)then Exit;
  if FBundlesAppearance<>nil then FBundlesAppearance.AlphaToCoverage:=RiderHairProbeCoverage;
  Frame:=Scene.Transform*FRoot.Matrix;
  WorldFrame:=Frame;if Scene.HasWorldTransform then WorldFrame:=Scene.WorldTransform*FRoot.Matrix;
  { The actual visible pass selects LOD, including editor cameras. Physics
    consumes its last selection; shadow rendering never changes solver detail. }
  if FScreenPixels>0 then begin
    Quality:=EnsureRange(RiderHairQuality,0,3);Pixels:=FScreenPixels*QualityScale[Quality];
    NewDetail:=EnsureRange((Pixels-30)/100,0,1);if Quality=0 then NewDetail:=0;
    if Abs(NewDetail-FDetail)>0.025 then begin FDetail:=NewDetail;FDetailField.Send(FDetail) end;
  end;
  if Dt<=0 then begin
    if FStyle in [rhsLongBraid,rhsDoubleBraids,rhsDreadlocks]then SendPhysics;
    Exit;
  end;
  if not RiderHairProbePhysics then Exit;
  FPhysics.SetDetail(FLod);
  FTickAccum:=FTickAccum+Dt;
  if(FLod>=2)and(FTickAccum<1/30)then Exit;
  { Measure head movement in the bike frame. Convert environmental forces from
    world into that same frame, without subtracting kilometre-scale positions. }
  ToParent:=TMatrix4.Identity;
  if WorldFrame.TryInverse(WorldInverse)then ToParent:=Frame*WorldInverse;
  Forward:=Scene.LocalToWorldDirection(Vector3(0,0,1));
  if Forward.LengthSqr>1e-6 then Forward:=Forward.Normalize;
  if Assigned(RiderWindSampler)then
    Wind:=RiderWindSampler(WorldFrame.MultPoint(Vector3(0,0.04,-0.02)))
  else Wind:=RiderWindWorld;
  Wind:=Wind-Forward*Max(Speed,0);
  Wind:=ToParent.MultDirection(Wind);
  Gravity:=ToParent.MultDirection(Vector3(0,-9.81,0));
  FPhysics.Advance(FTickAccum,Frame,Gravity,Wind,ToParent.MultDirection(Forward),Speed);
  FTickAccum:=0;SendPhysics;
end;
procedure TRiderHair.SetTorso(Scene:TCastleScene;const A,B:TVector3;Radius:Single);
var Inv,Frame:TMatrix4;Scale:Single;
begin
  if Scene=nil then Exit;
  Frame:=Scene.Transform*FRoot.Matrix;
  if not Frame.TryInverse(Inv)then Exit;
  Scale:=Max(0.1,Frame.MultDirection(Vector3(0,1,0)).Length);
  FPhysics.SetTorso(Inv.MultPoint(A),Inv.MultPoint(B),Radius/Scale);
end;
function TRiderHair.CaptureReplay:THairMotionState;
begin
  Result:=FPhysics.State;Result.PendingTime:=FTickAccum;
  Result.DetailLevel:=FLod;Result.ShaderDetail:=FDetail;
end;
procedure TRiderHair.RestoreReplay(const Value:THairMotionState);
begin
  FPhysics.Restore(Value);FTickAccum:=Value.PendingTime;
  FLod:=EnsureRange(Value.DetailLevel,0,HairLodCount-1);
  FDetail:=EnsureRange(Value.ShaderDetail,0,1);FDetailField.Send(FDetail);SendPhysics;
end;
procedure TRiderHair.DebugJson(Result:TJSONObject);
begin
  Result.Add('style',HairIds[FStyle]);Result.Add('triangles',TriangleCount);Result.Add('lod',FLod);
  Result.Add('screen_pixels',FScreenPixels);Result.Add('shadow_pixels',FShadowPixels);
  Result.Add('shadow_lod',FShadowLod);Result.Add('shadow_triangles',LodTriangleCount(FShadowLod));
  Result.Add('groom_loaded',FData<>nil);Result.Add('guide_count',HairGuideCount);
  Result.Add('simulated_guide_count',FPhysics.ActiveGuideCount);
  Result.Add('displacement_m',FPhysics.MaxDisplacement);Result.Add('length_error_m',FPhysics.MaxLengthError);
  Result.Add('motion_time',FPhysics.State.Time);Result.Add('helmet',FHelmet);
  Result.Add('physics_hz',1/Max(FPhysics.State.StepSeconds,1/120));
end;
end.
