unit RiderHeadAppearance;
{$mode objfpc}{$H+}
interface
uses RiderShaderSharing, Classes,X3DNodes,X3DFields,CastleVectors,fpjson,TripoRig,RiderFace;
type
  TRiderHeadwear=(rhwNone,rhwHelmet,rhwBandana,rhwCap);
  TRiderBeard=(rbNone,rbStubble,rbShort,rbFull,rbGoatee);
  TRiderMustache=(rmNone,rmPencil,rmClassic,rmHandlebar);
  TRiderHeadAppearance=class
  private
    type TFitVertex=record
      Id:array[0..2]of Integer;
      Weight,Offset:TVector3;
    end;
    TFitShape=record
      Geometry:TIndexedTriangleSetNode;
      Vertices:array of TFitVertex;
    end;
    var
    FFits:array of TFitShape;
    FFitData:TMemoryStream;
    FRoot:TMatrixTransformNode;
    FParts:TX3DRootNode;
    FHead:TVector3;
    FScale:Single;
    FHeadwear:TRiderHeadwear;
    FBeard:TRiderBeard;
    FMustache:TRiderMustache;
    FHeadNodes:array[TRiderHeadwear]of TTransformNode;
    FBeardNodes:array[TRiderBeard]of TTransformNode;
    FMustacheNodes:array[TRiderMustache]of TTransformNode;
    FHairColors,FClothColors:array of TSFVec3f;
    FHairAppearance:TAppearanceNode;
    FFaceField:TSFVec4f;
    FLastBlink:Single;
    FAtlasPath:String;
    FHairColor,FClothColor,FLastFace,FMouth,FJaw:TVector3;
    FBuildKind:Integer;
    procedure AttachMaterial(Node:TX3DNode);
    procedure AttachFit(Node:TX3DNode);
    procedure ConfigureLod(Node:TTransformNode);
  public
    constructor Create(Parent:TAbstractGroupingNode;const Path:String;
      const Head:TVector3;Scale:Single);
    procedure Follow(const Matrix:TMatrix4);
    procedure Select(Headwear:TRiderHeadwear;Beard:TRiderBeard;Mustache:TRiderMustache);
    procedure SetHairColor(const Color:TVector3);
    procedure SetClothColor(const Color:TVector3);
    procedure UpdateFace(Face:TRiderFace);
    procedure FitToRig(Rig:TTripoRig);
    procedure DebugJson(Result:TJSONObject);
    property Root:TMatrixTransformNode read FRoot;
  end;
function HeadwearId(V:TRiderHeadwear):String;
function HeadwearCaption(V:TRiderHeadwear):String;
function ParseHeadwear(const S:String):TRiderHeadwear;
function BeardId(V:TRiderBeard):String;
function BeardCaption(V:TRiderBeard):String;
function ParseBeard(const S:String):TRiderBeard;
function MustacheId(V:TRiderMustache):String;
function MustacheCaption(V:TRiderMustache):String;
function ParseMustache(const S:String):TRiderMustache;
implementation
uses SysUtils,Math,ZStream,X3DLoad,CastleURIUtils,CastleRenderOptions,CastleRenderContext,RiderHairMaterial;
const
  HeadIds:array[TRiderHeadwear]of String=('none','helmet','bandana','cap');
  HeadNames:array[TRiderHeadwear]of String=('No headwear','Helmet','Bandana','Cycling cap');
  BeardIds:array[TRiderBeard]of String=('none','stubble','short','full','goatee');
  BeardNames:array[TRiderBeard]of String=('Clean shaven','Stubble','Short beard','Full beard','Goatee');
  MustacheIds:array[TRiderMustache]of String=('none','pencil','classic','handlebar');
  MustacheNames:array[TRiderMustache]of String=('No mustache','Pencil mustache','Classic mustache','Handlebar mustache');
function HeadwearId(V:TRiderHeadwear):String;begin Result:=HeadIds[V] end;
function HeadwearCaption(V:TRiderHeadwear):String;begin Result:=HeadNames[V] end;
function ParseHeadwear(const S:String):TRiderHeadwear;
var V:TRiderHeadwear;
begin for V:=Low(V)to High(V)do if SameText(S,HeadIds[V])then Exit(V);Result:=rhwHelmet end;
function BeardId(V:TRiderBeard):String;begin Result:=BeardIds[V] end;
function BeardCaption(V:TRiderBeard):String;begin Result:=BeardNames[V] end;
function ParseBeard(const S:String):TRiderBeard;
var V:TRiderBeard;
begin for V:=Low(V)to High(V)do if SameText(S,BeardIds[V])then Exit(V);Result:=rbNone end;
function MustacheId(V:TRiderMustache):String;begin Result:=MustacheIds[V] end;
function MustacheCaption(V:TRiderMustache):String;begin Result:=MustacheNames[V] end;
function ParseMustache(const S:String):TRiderMustache;
var V:TRiderMustache;
begin for V:=Low(V)to High(V)do if SameText(S,MustacheIds[V])then Exit(V);Result:=rmNone end;

function LinearColor(const C:TVector3):TVector3;
var I:Integer;V:Single;
begin
  for I:=0 to 2 do begin V:=EnsureRange(C.Data[I],0,1);
    if V<=0.04045 then Result.Data[I]:=V/12.92 else Result.Data[I]:=Power((V+0.055)/1.055,2.4) end;
end;

constructor TRiderHeadAppearance.Create(Parent:TAbstractGroupingNode;
  const Path:String;const Head:TVector3;Scale:Single);
var H:TRiderHeadwear;B:TRiderBeard;M:TRiderMustache;N:TX3DNode;Stream:TFileStream;FitPath:String;Z:TDecompressionStream;Magic:array[0..3]of Char;Version:LongWord;
  function Find(const Name:String):TTransformNode;
  var Node:TX3DNode;
  begin
    Node:=FParts.TryFindNodeByName(TTransformNode,Name,False);
    if Node is TTransformNode then Result:=TTransformNode(Node) else Result:=nil;
  end;
begin
  inherited Create;FHead:=Head;FScale:=Scale;
  FAtlasPath:=ExtractFilePath(Path)+'strands.png';FLastFace:=Vector3(-1,-1,-1);
  FRoot:=TMatrixTransformNode.Create('RiderHeadAppearance');
  FHairColor:=Vector3(0.26,0.17,0.105);FClothColor:=Vector3(1,1,1);
  FMouth:=Vector3(0,-0.023,0.125);FJaw:=Vector3(0,0.008,-0.001);
  if FileExists(Path)then begin
    FParts:=LoadNode(FilenameToUriSafe(Path));FRoot.AddChildren(FParts);
    N:=Find('HeadMouth');if N<>nil then FMouth:=TTransformNode(N).Translation;
    N:=Find('HeadJawPivot');if N<>nil then FJaw:=TTransformNode(N).Translation;
    for H:=rhwBandana to High(H)do begin
      FHeadNodes[H]:=Find('Headwear_'+HeadIds[H]);FBuildKind:=0;
      if FHeadNodes[H]<>nil then FHeadNodes[H].EnumerateNodes(TShapeNode,@AttachMaterial,False);
    end;
    for B:=rbStubble to High(B)do begin
      FBeardNodes[B]:=Find('HeadBeard_'+BeardIds[B]);FBuildKind:=Ord(B);
      if FBeardNodes[B]<>nil then begin
        FBeardNodes[B].EnumerateNodes(TShapeNode,@AttachMaterial,False);
        ConfigureLod(FBeardNodes[B]);
      end;
    end;
    for M:=rmPencil to High(M)do begin
      FMustacheNodes[M]:=Find('HeadMustache_'+MustacheIds[M]);FBuildKind:=4+Ord(M);
      if FMustacheNodes[M]<>nil then begin
        FMustacheNodes[M].EnumerateNodes(TShapeNode,@AttachMaterial,False);
        ConfigureLod(FMustacheNodes[M]);
      end;
    end;
    FitPath:=ChangeFileExt(Path,'.fit.bin');
    if FileExists(FitPath)then begin
      Stream:=TFileStream.Create(FitPath,fmOpenRead or fmShareDenyWrite);
      try
        Stream.ReadBuffer(Magic,SizeOf(Magic));Stream.ReadBuffer(Version,SizeOf(Version));
        if (Magic<>'RZHF')or(Version<>2)then raise Exception.Create('Unsupported head binding format');
        Z:=TDecompressionStream.Create(Stream);FFitData:=TMemoryStream.Create;
        try
          FFitData.CopyFrom(Z,0);
          FParts.EnumerateNodes(TShapeNode,@AttachFit,False);
        finally FreeAndNil(FFitData);Z.Free end;
      finally Stream.Free end;
    end;
  end;
  Select(rhwHelmet,rbNone,rmNone);Follow(TMatrix4.Identity);Parent.AddChildren(FRoot);
end;

procedure TRiderHeadAppearance.ConfigureLod(Node:TTransformNode);
var L:TLODNode;Child:TAbstractChildNode;
begin
  if Node.FdChildren.Count<>3 then Exit;
  L:=TLODNode.Create(Node.X3DName+'_Detail');
  L.FdCenter.Value:=FMouth;L.FdRange.Send([1.25,4.5]);
  while Node.FdChildren.Count>0 do begin
    Child:=TAbstractChildNode(Node.FdChildren[0]);L.AddChildren(Child);Node.RemoveChildren(Child);
  end;
  Node.AddChildren(L);
end;

procedure TRiderHeadAppearance.AttachFit(Node:TX3DNode);
type TRow=packed record Id:array[0..2]of LongWord;Data:array[0..23]of Single end;
var S:TShapeNode;I,J,K,F:Integer;Count,Vertices:LongWord;NameSize:Word;Name:String;
  Geo:TIndexedTriangleSetNode;Row:TRow;
  UV,Flow,Seed:TFloatVertexAttributeNode;Pose:array[0..3]of TFloatVertexAttributeNode;
  function Attribute(const Name:String;Components:Integer):TFloatVertexAttributeNode;
  begin
    Result:=TFloatVertexAttributeNode.Create;Result.NameField:=Name;Result.NumComponents:=Components;
    Geo.FdAttrib.Add(Result);
  end;
begin
  S:=TShapeNode(Node);if not(S.Geometry is TIndexedTriangleSetNode)then Exit;
  FFitData.Position:=0;FFitData.ReadBuffer(Count,4);
  if (Count=0)or(Count>128) then raise Exception.Create('Invalid head binding shape count');
  for I:=0 to Count-1 do begin
    FFitData.ReadBuffer(NameSize,2);if (NameSize=0)or(NameSize>512) then raise Exception.Create('Invalid head binding name');
    SetLength(Name,NameSize);if NameSize>0 then FFitData.ReadBuffer(Name[1],NameSize);
    FFitData.ReadBuffer(Vertices,4);
    if Int64(Vertices)*SizeOf(TRow)>FFitData.Size-FFitData.Position then raise Exception.Create('Truncated head binding');
    if Pos(Name,S.X3DName)<>1 then begin FFitData.Seek(Int64(Vertices)*SizeOf(TRow),soCurrent);Continue end;
    Geo:=TIndexedTriangleSetNode(S.Geometry);
    if Vertices<>TCoordinateNode(Geo.Coord).FdPoint.Count then raise Exception.Create('Head binding vertex mismatch: '+Name);
    F:=Length(FFits);SetLength(FFits,F+1);FFits[F].Geometry:=Geo;
    SetLength(FFits[F].Vertices,Vertices);Geo.Solid:=False;
    UV:=Attribute('haUV',2);Flow:=Attribute('haFlow',3);
    Seed:=Attribute('haSeed',1);for J:=0 to 3 do Pose[J]:=Attribute('haPose'+IntToStr(J),3);
    for J:=0 to Integer(Vertices)-1 do begin
      FFitData.ReadBuffer(Row,SizeOf(Row));
      for K:=0 to 2 do begin
        FFits[F].Vertices[J].Id[K]:=Row.Id[K];
        FFits[F].Vertices[J].Weight.Data[K]:=Row.Data[K];
        FFits[F].Vertices[J].Offset.Data[K]:=Row.Data[K+3];
        Flow.FdValue.Items.Add(Row.Data[K+8]);
      end;
      for K:=0 to 1 do UV.FdValue.Items.Add(Row.Data[K+6]);
      for K:=0 to 11 do Pose[K div 3].FdValue.Items.Add(Row.Data[K+12]);
      Seed.FdValue.Items.Add(Row.Data[11]);
    end;
    Break;
  end;
end;

procedure TRiderHeadAppearance.FitToRig(Rig:TTripoRig);
var I,J,K,A,B,C:Integer;Geo:TIndexedTriangleSetNode;Coord:TCoordinateNode;Normals:TNormalNode;
  P,N:TVector3;V:^TFitVertex;
begin
  if Rig=nil then Exit;
  FLastFace:=Vector3(-1,-1,-1);
  for I:=0 to High(FFits)do begin
    Geo:=FFits[I].Geometry;Coord:=TCoordinateNode(Geo.Coord);Normals:=TNormalNode(Geo.Normal);
    for J:=0 to High(FFits[I].Vertices)do begin
      V:=@FFits[I].Vertices[J];P:=TVector3.Zero;
      for K:=0 to 2 do begin
        A:=V^.Id[K];if(A<0)or(A>=Rig.VertexCount)then Exit;
        P:=P+Vector3(Rig.Positions[A].X,Rig.Positions[A].Y,Rig.Positions[A].Z)*V^.Weight.Data[K];
      end;
      Coord.FdPoint.Items[J]:=(P-FHead)/FScale+V^.Offset;
      Normals.FdVector.Items[J]:=TVector3.Zero;
    end;
    for J:=0 to Geo.FdIndex.Count div 3-1 do begin
      A:=Geo.FdIndex.Items[J*3];B:=Geo.FdIndex.Items[J*3+1];C:=Geo.FdIndex.Items[J*3+2];
      N:=TVector3.CrossProduct(Coord.FdPoint.Items[B]-Coord.FdPoint.Items[A],Coord.FdPoint.Items[C]-Coord.FdPoint.Items[A]);
      Normals.FdVector.Items[A]:=Normals.FdVector.Items[A]+N;
      Normals.FdVector.Items[B]:=Normals.FdVector.Items[B]+N;
      Normals.FdVector.Items[C]:=Normals.FdVector.Items[C]+N;
    end;
    for J:=0 to Normals.FdVector.Count-1 do Normals.FdVector.Items[J]:=Normals.FdVector.Items[J].Normalize;
    Coord.FdPoint.Changed;Normals.FdVector.Changed;
  end;
end;

procedure TRiderHeadAppearance.AttachMaterial(Node:TX3DNode);
var Sh:TShapeNode;App:TAppearanceNode;Mat:TPhysicalMaterialNode;
  E:TEffectNode;V,F:TEffectPartNode;Color:TSFVec3f;Tex:TImageTextureNode;
  TextureField:TSFNode;
begin
  Sh:=TShapeNode(Node);
  if FBuildKind=0 then begin
    if (Sh.Appearance=nil)or(Sh.Appearance.Material=nil)then Exit;
    { glTF keeps the material name on Appearance, not PhysicalMaterial. }
    if (Pos('HeadCloth',Sh.Appearance.X3DName)<>1)and
       (Pos('HeadCloth',Sh.Appearance.Material.X3DName)<>1)then Exit;
  end else if FHairAppearance<>nil then begin Sh.Appearance:=FHairAppearance;Exit end;
  App:=TAppearanceNode.Create;Mat:=TPhysicalMaterialNode.Create;
  Mat.BaseColor:=Vector3(1,1,1);Mat.Metallic:=0;Mat.Roughness:=0.75;App.Material:=Mat;
  E:=TEffectNode.Create;E.Language:=slGLSL;E.UniformMissing:=umIgnore;App.FdEffects.Add(E);
  V:=TEffectPartNode.Create;V.ShaderType:=stVertex;
  F:=TEffectPartNode.Create;F.ShaderType:=stFragment;
  if FBuildKind=0 then begin
    Color:=TSFVec3f.Create(E,True,'haColor',LinearColor(FClothColor));E.AddCustomField(Color);
    SetLength(FClothColors,Length(FClothColors)+1);FClothColors[High(FClothColors)]:=Color;
    V.Contents:='varying vec3 haRest;void PLUG_vertex_object_space_change(inout vec4 p,inout vec3 n){haRest=p.xyz;}';
    F.Contents:=
      'uniform vec3 haColor;varying vec3 haRest;'+#10+
      'void PLUG_main_texture_apply(inout vec4 c,const vec3 n){vec2 uv=haRest.xy*1100.0;'+#10+
      ' float aa=exp2(-3.0*dot(fwidth(uv),fwidth(uv)));'+#10+
      ' c.rgb=haColor*(0.92+0.06*sin(uv.x*6.283)*sin(uv.y*6.283)*aa);}';
  end else begin
    FHairAppearance:=App;App.AlphaMode:=amMask;App.AlphaCutoff:=0.12;App.AlphaToCoverage:=True;
    Color:=TSFVec3f.Create(E,True,'rhColor',LinearColor(FHairColor));E.AddCustomField(Color);
    SetLength(FHairColors,1);FHairColors[0]:=Color;
    FFaceField:=TSFVec4f.Create(E,True,'haFace',Vector4(0,0,0,0));E.AddCustomField(FFaceField);
    Tex:=TImageTextureNode.Create('FacialHairStrands');Tex.SetUrl([FilenameToUriSafe(FAtlasPath)]);
    Tex.RepeatS:=False;Tex.RepeatT:=False;
    TextureField:=TSFNode.Create(E,True,'rhAtlas',[TImageTextureNode]);TextureField.Value:=Tex;E.AddCustomField(TextureField);
    V.Contents:=
      'attribute vec2 haUV;attribute vec3 haFlow;attribute float haSeed;'+#10+
      'attribute vec3 haPose0,haPose1,haPose2,haPose3;uniform vec4 haFace;' + #10 + '#ifndef GL_ES' + #10 + 'uniform mat3 castle_NormalMatrix;' + #10 + '#endif' + #10 + ''+#10+
      'varying vec2 rhUV;varying vec3 rhFlow;varying float rhSeed;'+#10+
      'void PLUG_vertex_object_space_change(inout vec4 p,inout vec3 n){'+#10+
      ' float squint=(1.0-haFace.w)*min(1.0,0.35*haFace.y+0.75*haFace.z);'+#10+
      ' p.xyz+=haPose0*haFace.x+haPose1*haFace.y+haPose2*haFace.z+haPose3*squint;}'+#10+
      'void PLUG_vertex_eye_space(const vec4 v,const vec3 n){rhFlow=castle_NormalMatrix*haFlow;rhUV=haUV;rhSeed=haSeed;}';
    F.Contents:=
      'uniform sampler2D rhAtlas;uniform vec3 rhColor;varying vec2 rhUV;varying vec3 rhFlow;varying float rhSeed;'+#10+
      'vec3 rhTangent,rhAlbedo;float rhDetail=1.0;'+#10+
      'void PLUG_fragment_eye_space(const vec4 v,inout vec3 n){vec3 dx=dFdx(v.xyz),dy=dFdy(v.xyz);'+#10+
      ' vec3 g=cross(dx,dy);if(dot(g,g)>1e-18)n=normalize(g)*sign(dot(g,n));'+#10+
      ' vec3 t=dy*dFdx(rhUV.x)-dx*dFdy(rhUV.x);'+#10+
      ' rhTangent=normalize(dot(t,t)>1e-18?t:rhFlow+vec3(1e-7));'+#10+
      ' rhDetail=1.0-smoothstep(1.0,5.0,length(v.xyz));}'+#10+
      'void PLUG_main_texture_apply(inout vec4 c,const vec3 n){vec4 a=texture2D(rhAtlas,rhUV);'+#10+
      ' float cover=a.a*smoothstep(0.0,0.065,rhUV.y);float edge=max(fwidth(cover),0.05);'+#10+
      ' c.a=clamp((cover-0.30)/edge+0.5,0.0,1.0);if(c.a<0.12)discard;'+#10+
      ' rhAlbedo=rhColor*mix(0.45,1.12,a.r)*(0.88+0.24*rhSeed);c.rgb=rhAlbedo;}'+#10+
      'void PLUG_material_metallic_roughness(inout float m,inout float r){m=0.0;r=0.70;}'+#10+
      RiderHairLightShader;
  end;
  E.SetParts([V,F]);ShareRiderEffect(E);Sh.Appearance:=App;
end;

procedure TRiderHeadAppearance.Follow(const Matrix:TMatrix4);
begin FRoot.Matrix:=Matrix*TranslationMatrix(FHead)*ScalingMatrix(Vector3(FScale,FScale,FScale)) end;
procedure TRiderHeadAppearance.Select(Headwear:TRiderHeadwear;Beard:TRiderBeard;Mustache:TRiderMustache);
var H:TRiderHeadwear;B:TRiderBeard;M:TRiderMustache;
begin
  FHeadwear:=Headwear;FBeard:=Beard;FMustache:=Mustache;
  for H:=Low(H)to High(H)do if FHeadNodes[H]<>nil then FHeadNodes[H].Visible:=H=Headwear;
  for B:=Low(B)to High(B)do if FBeardNodes[B]<>nil then FBeardNodes[B].Visible:=B=Beard;
  for M:=Low(M)to High(M)do if FMustacheNodes[M]<>nil then FMustacheNodes[M].Visible:=M=Mustache;
end;
procedure TRiderHeadAppearance.SetHairColor(const Color:TVector3);
var I:Integer;
begin
  FHairColor:=Color;for I:=0 to High(FHairColors)do FHairColors[I].Send(LinearColor(Color));
end;
procedure TRiderHeadAppearance.SetClothColor(const Color:TVector3);
var I:Integer;
begin
  FClothColor:=Color;for I:=0 to High(FClothColors)do FClothColors[I].Send(LinearColor(Color));
end;
procedure TRiderHeadAppearance.UpdateFace(Face:TRiderFace);
begin
  if (Face=nil)or(FFaceField=nil)or((FBeard=rbNone)and(FMustache=rmNone))then Exit;
  if ((Face.Controls-FLastFace).LengthSqr<1e-12)and(Abs(Face.EyeControls.X-FLastBlink)<1e-6)then Exit;
  FLastFace:=Face.Controls;FLastBlink:=Face.EyeControls.X;
  FFaceField.Send(Vector4(FLastFace.X,FLastFace.Y,FLastFace.Z,FLastBlink));
end;
procedure TRiderHeadAppearance.DebugJson(Result:TJSONObject);
begin
  Result.Add('headwear',HeadwearId(FHeadwear));Result.Add('beard',BeardId(FBeard));
  Result.Add('mustache',MustacheId(FMustache));Result.Add('head_parts_loaded',FParts<>nil);
  Result.Add('head_fit_shapes',Length(FFits));
  Result.Add('headwear_color',TJSONArray.Create([FClothColor.X,FClothColor.Y,FClothColor.Z]));
  Result.Add('headwear_color_materials',Length(FClothColors));
end;
end.
