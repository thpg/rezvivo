unit RiderPoseCorrectives;

{$mode objfpc}{$H+}

{ Static sparse morph atlas exported alongside an anatomical avatar.
  Both animation paths deform vertices on the GPU. The legacy CPU IK only
  uploads joint angles; the procedural path derives them from its own solve. }
interface

uses Classes, SysUtils, Math, fpjson, jsonparser, CastleUtils, CastleVectors, CastleImages,
  CastleScene, X3DNodes, X3DFields, TripoRig, RiderBodyParameters, RiderBodyDeformation;

type
  TRiderPoseCorrectives = class
  private
    FRig: TTripoRig;
    FTexture: TImageTextureNode;
    FCpuEffect: TEffectNode;
    FAngles: TMFFloat;
    FAngleList: TSingleList;
    FWeightsSource: string;
    FWidth, FHeight: Integer;
    FReady: Boolean;
    FGpuActive, FNativeSkinActive: Boolean;
    FSkin: TSkinNode;
    FBodyContact: Boolean;
    FContactCoefficients: array[0..2, 0..3] of Single;
    FContact: TVector3;
    FBody: TRiderBodyDeformation;
    FFaceValue: TVector4;
    FCpuFace, FGpuFace: TSFVec4f;
  public
    NeededJoints: array of Boolean;
    constructor Create;
    destructor Destroy; override;
    function Load(const ModelPath: string; Scene: TCastleScene;
      Skin: TSkinNode; Rig: TTripoRig): Boolean;
    function ShaderSource: string;
    procedure AddUniforms(Effect: TEffectNode);
    procedure SetGpuActive(Enabled: Boolean);
    procedure SetNativeSkinActive(Enabled: Boolean);
    procedure UpdateCpuPose;
    procedure SetBodyParameters(const Value: TRiderBodyParameters);
    procedure SetFaceControls(const Controls: TVector3; Blink: Single);
    procedure DetachGpu;
    property Ready: Boolean read FReady;
    property Body: TRiderBodyDeformation read FBody;
  end;

implementation

uses GltfCore, RiderCorrectiveData;

constructor TRiderPoseCorrectives.Create;
begin
  inherited;
  FNativeSkinActive := True;
  FAngleList := TSingleList.Create;
end;

destructor TRiderPoseCorrectives.Destroy;
begin
  FBody.Free;
  FAngleList.Free;
  if FCpuEffect <> nil then
  begin
    FCpuEffect.KeepExistingEnd;
    FCpuEffect.FreeIfUnused;
  end;
  if FTexture <> nil then
  begin
    FTexture.KeepExistingEnd;
    FTexture.FreeIfUnused;
  end;
  inherited;
end;

function TRiderPoseCorrectives.Load(const ModelPath: string; Scene: TCastleScene;
  Skin: TSkinNode; Rig: TTripoRig): Boolean;
var
  Metadata: TJSONObject;
  Root, ShapeInfo, Control, Variables, Contact: TJSONObject;
  Shapes, Controls: TJSONArray;
  Coefficients: TJSONArray;
  FileData: TMemoryStream;
  Lines: TStringList;
  Pixels: TRGBAlphaFloatImage;
  Props: TTexturePropertiesNode;
  Shape: TShapeNode;
  Geom: TAbstractComposedGeometryNode;
  Attr: TFloatVertexAttributeNode;
  Part: TEffectPartNode;
  Apps: TList;
  Span: TVector3;
  Texel: TVector4;
  ControlMasks: array of Integer;
  I, K, V, J, Count, Entry, First, Entries, ControlId, Mask, Axis: Integer;
  Expr, JointName: string;

const ContactKeys: array[0..2] of string = ('startDegrees', 'endDegrees', 'strength');

  function JointMask(Index: Integer): Integer;
  var Name: String;
  begin
    Result := 0;
    while Index >= 0 do
    begin
      Name := Rig.JointName[Index];
      if Name = 'R_Thigh' then Exit(1);
      if Name = 'L_Thigh' then Exit(2);
      if Name = 'R_Clavicle' then Exit(8);
      if Name = 'L_Clavicle' then Exit(16);
      if (Name = 'Waist') or (Name = 'Spine') or
         (Name = 'Spine01') or (Name = 'Spine02') then Exit(4);
      Index := Rig.JointParent[Index];
    end;
  end;
begin
  Result := False;
  if (Skin = nil) or (Rig = nil) then Exit;
  FileData := OpenRiderCorrectiveData(ModelPath, Metadata);
  if FileData = nil then Exit;
  try
    if not (Metadata is TJSONObject) then Exit;
    Root := TJSONObject(Metadata);
    if Root.Get('version', 0) <> 1 then Exit;
    { Mesh names, vertex counts and control joints are checked below. File
      length also changes for harmless JSON, contact and helmet edits. }
    FWidth := Root.Get('width', 0); FHeight := Root.Get('height', 0);
    if (FWidth < 1) or (FWidth > 8192) or (FHeight < 1) or (FHeight > 8192) then Exit;
    FRig := Rig;
    FSkin := Skin;
    Contact := ObjOf(Root, 'bodyContact');
    FBodyContact := Contact <> nil;
    if FBodyContact then
    begin
      if Contact.Get('version', 0) <> 1 then
        raise EReadError.Create('Unsupported avatar contact shape version');
      for I := 0 to 2 do
      begin
        Coefficients := ArrOf(Contact, ContactKeys[I]);
        if (Coefficients = nil) or (Coefficients.Count <> 4) then
          raise EReadError.Create('Invalid avatar contact coefficients');
        for K := 0 to 3 do
        begin
          FContactCoefficients[I,K] := Coefficients.Floats[K];
          if IsNan(FContactCoefficients[I,K]) or IsInfinite(FContactCoefficients[I,K]) then
            raise EReadError.Create('Non-finite avatar contact coefficient');
        end;
      end;
      SetBodyParameters(DefaultRiderBody(1));
    end;
    SetLength(NeededJoints, Rig.JointCount);
    Shapes := ArrOf(Root, 'shapes'); Controls := ArrOf(Root, 'controls');
    SetLength(ControlMasks, Controls.Count);
    Lines := TStringList.Create;
    try
      Lines.Add('float riderPsdWeight(int id) {');
      for I := 0 to Controls.Count - 1 do
      begin
        Control := Controls.Objects[I]; Variables := ObjOf(Control, 'variables');
        Lines.Add('  if (id == ' + IntToStr(I) + ') {');
        for K := 0 to Variables.Count - 1 do
        begin
          JointName := Variables.Items[K].AsString;
          Axis := 0;
          { Old atlases use the local X component. New controls can also use
            clavicular protraction and humeral abduction/twist. }
          if (Length(JointName)>2) and (JointName[Length(JointName)-1]=':') then
          begin
            case JointName[Length(JointName)] of
              'x': Axis:=0;
              'y': Axis:=1;
              'z': Axis:=2;
              else raise EReadError.Create('Invalid avatar corrective axis');
            end;
            Delete(JointName,Length(JointName)-1,2);
          end;
          J := Rig.JointIndexByName(JointName);
          if J < 0 then raise Exception.Create('Missing avatar corrective joint: ' + Variables.Items[K].AsString);
          NeededJoints[J] := True;
          ControlMasks[I] := ControlMasks[I] or JointMask(J);
          Lines.Add('    float ' + Variables.Names[K] + ' = riderPsdComponent(' + IntToStr(J) + ',' + IntToStr(Axis) + ');');
        end;
        Expr := Control.Get('glsl', '0.0');
        Lines.Add('    return ' + Expr + ';');
        Lines.Add('  }');
      end;
      Lines.Add('  return 0.0;'); Lines.Add('}');
      FWeightsSource := Lines.Text;
    finally Lines.Free end;
    Pixels := TRGBAlphaFloatImage.Create(FWidth, FHeight);
    try
      FileData.ReadBuffer(Pixels.RawPixels^, FWidth * FHeight * SizeOf(TVector4));
      FTexture := TImageTextureNode.Create;
      FTexture.KeepExistingBegin;
      Props := TTexturePropertiesNode.Create;
      { Data texels must never be resized by GLTextureScale or rounded to
        power-of-two dimensions (both are valid for ordinary surface images). }
      Props.GUITexture := True;
      Props.GenerateMipMaps := False;
      Props.FdMinificationFilter.Value := 'NEAREST_PIXEL';
      Props.FdMagnificationFilter.Value := 'NEAREST_PIXEL';
      FTexture.FdTextureProperties.Value := Props;
      FTexture.RepeatS := False; FTexture.RepeatT := False;
      FTexture.LoadFromImage(Pixels, True, ''); Pixels := nil;
      for I := 0 to Shapes.Count - 1 do
      begin
        ShapeInfo := Shapes.Objects[I]; Count := ShapeInfo.Get('vertices', 0);
        Shape := nil;
        for K := 0 to Skin.FdShapes.Count - 1 do
          if (Skin.FdShapes[K] is TShapeNode) and
             (Skin.FdShapes[K].X3DName = ShapeInfo.Get('name', '')) then
            Shape := TShapeNode(Skin.FdShapes[K]);
        if (Shape = nil) or not (Shape.Geometry is TAbstractComposedGeometryNode) then
          raise Exception.Create('Missing avatar corrective mesh: ' + ShapeInfo.Get('name', ''));
        Geom := TAbstractComposedGeometryNode(Shape.Geometry);
        if not (Geom.FdCoord.Value is TCoordinateNode) or
           (TCoordinateNode(Geom.FdCoord.Value).FdPoint.Count <> Count) then
          raise Exception.Create('Avatar corrective vertex count mismatch');
        Attr := TFloatVertexAttributeNode.Create;
        Attr.FdName.Value := 'riderPsdSpan'; Attr.NumComponents := 3;
        for V := 0 to Count - 1 do
        begin
          FileData.ReadBuffer(Span, SizeOf(Span));
          { A corrective can depend on joints that do not skin this vertex:
            e.g. a raised thigh compresses the abdomen, or a reaching arm
            changes the scapula. Derive dependencies from the actual controls
            at load time; authoring/roundtrip tools may leave span.z at zero. }
          First := Round(Span.X); Entries := Round(Span.Y); Mask := 0;
          if (First < 0) or (Entries < 0) or
             (Int64(First) + Int64(Entries) * 2 > Int64(FWidth) * FHeight) then
            raise Exception.Create('Invalid avatar corrective span');
          for Entry := 0 to Entries - 1 do
          begin
            Move((PByte(FileData.Memory) + (First + Entry * 2) * SizeOf(TVector4))^,
              Texel, SizeOf(Texel));
            ControlId := Round(Texel.W);
            if (ControlId < 0) or (ControlId >= Length(ControlMasks)) then
              raise Exception.Create('Invalid avatar corrective control');
            Mask := Mask or ControlMasks[ControlId];
          end;
          Attr.FdValue.Items.Add(Span.X);
          Attr.FdValue.Items.Add(Span.Y);
          Attr.FdValue.Items.Add(Mask);
        end;
        Geom.FdAttrib.Add(Attr);
      end;
      if FileData.Position <> FileData.Size then raise Exception.Create('Avatar corrective data size mismatch');
    finally Pixels.Free end;

    FBody:=TRiderBodyDeformation.Create;
    if not FBody.Load(ModelPath,Skin,Rig) then FreeAndNil(FBody);
    FCpuEffect := TEffectNode.Create('RiderCpuPoseCorrectives');
    FCpuEffect.KeepExistingBegin;
    FNativeSkinActive := Scene.RenderOptions.SkinnedAnimationShaders;
    FCpuEffect.Enabled := FNativeSkinActive and not FGpuActive;
    FCpuEffect.Language := slGLSL;
    FCpuEffect.InternalCacheVertexAnimation := True;
    FAngles := TMFFloat.Create(FCpuEffect, True, 'uRiderPsdAngles', []);
    for I := 0 to Rig.JointCount * 3 - 1 do FAngles.Items.Add(0);
    FCpuEffect.AddCustomField(FAngles);
    AddUniforms(FCpuEffect);
    Part := TEffectPartNode.Create;
    Part.FdType.Value := 'VERTEX';
    Part.Contents := 'mat4 skinMatrix;' + LineEnding +
      'uniform float uRiderPsdAngles[' + IntToStr(Rig.JointCount * 3) + '];' + LineEnding +
      'float riderPsdComponent(int j,int axis) { return uRiderPsdAngles[j*3+axis]; }' + LineEnding + ShaderSource;
    if FBody<>nil then
      Part.Contents:=Part.Contents+
      'attribute vec4 castle_Vertex;attribute vec3 castle_Normal;'+LineEnding+
      'attribute vec4 castle_SkinWeights0;attribute vec4 castle_SkinJoints0;'+LineEnding+
      'mat4 getJointMatrix(int j);'+LineEnding+
      '#ifdef RIDER_SURFACE_MOTION'+LineEnding+'vec3 riderSurfaceOffset();'+LineEnding+'#endif'+LineEnding+
      FBody.ShaderSource('getJointMatrix')+
      'void PLUG_vertex_object_space(inout vec4 vertex,inout vec3 normal){'+LineEnding+
      'vec3 dp,dn;riderPsdOffset(dp,dn);vec3 p=castle_Vertex.xyz+dp;'+LineEnding+
      '#ifdef RIDER_SURFACE_MOTION'+LineEnding+'p+=riderSurfaceOffset();'+LineEnding+'#endif'+LineEnding+
      'vec3 n=vec3(0.0,1.0,0.0);'+LineEnding+
      '#if !defined(CASTLE_SHADOW_DEPTH) || defined(CASTLE_CACHE_DEFORMATION)'+LineEnding+
      'n=castle_Normal+dn;'+LineEnding+'#endif'+LineEnding+
      'vec3 outP,outN;bodyDeform(p,n,castle_SkinWeights0,ivec4(castle_SkinJoints0+vec4(.5)),outP,outN);'+LineEnding+
      'vertex=vec4(outP,1.0);normal=outN;}'+LineEnding
    else Part.Contents:=Part.Contents+
      'void PLUG_vertex_object_space(inout vec4 vertex, inout vec3 normal) {' + LineEnding +
      '  vec3 dp, dn; riderPsdOffset(dp, dn);' + LineEnding +
      '  vertex += skinMatrix * vec4(dp, 0.0);' + LineEnding +
      '  normal += mat3(skinMatrix) * dn;' + LineEnding + '}';
    FCpuEffect.FdParts.Add(Part);
    Apps := TList.Create;
    try
      for I := 0 to Skin.FdShapes.Count - 1 do
        if Skin.FdShapes[I] is TShapeNode then
        begin
          Shape := TShapeNode(Skin.FdShapes[I]);
          if (Shape.Appearance <> nil) and (Apps.IndexOf(Shape.Appearance) < 0) then
          begin
            Apps.Add(Shape.Appearance); Shape.Appearance.FdEffects.Add(FCpuEffect);
          end;
        end;
    finally Apps.Free end;
    FCpuEffect.Scene := Scene;
    FReady := True;
    Result := True;
  finally FileData.Free; Metadata.Free end;
end;

procedure TRiderPoseCorrectives.AddUniforms(Effect: TEffectNode);
var TextureField: TSFNode; FaceField: TSFVec4f;
begin
  FaceField:=TSFVec4f.Create(Effect,True,'uRiderFaceShape',FFaceValue);
  Effect.AddCustomField(FaceField);
  if Effect=FCpuEffect then FCpuFace:=FaceField else FGpuFace:=FaceField;
  if FBody<>nil then FBody.AddUniforms(Effect,Effect<>FCpuEffect);
  TextureField := TSFNode.Create(Effect, True, 'uRiderPsdAtlas', [TImageTextureNode]);
  TextureField.Value := FTexture;
  Effect.AddCustomField(TextureField);
  Effect.AddCustomField(TSFVec2f.Create(Effect, True, 'uRiderPsdSize', Vector2(FWidth, FHeight)));
  if FBodyContact then
    Effect.AddCustomField(TSFVec3f.Create(Effect, True, 'uRiderPsdContact', FContact));
end;

procedure TRiderPoseCorrectives.DetachGpu;
begin
  FGpuFace:=nil;
  if FBody<>nil then FBody.DetachGpu;
end;

procedure TRiderPoseCorrectives.SetFaceControls(const Controls:TVector3; Blink:Single);
var Value:TVector4;
begin
  Value:=Vector4(Controls.X,Controls.Y,Controls.Z,Blink);
  if (Value.X=FFaceValue.X)and(Value.Y=FFaceValue.Y)and
     (Value.Z=FFaceValue.Z)and(Value.W=FFaceValue.W)then Exit;
  FFaceValue:=Value;
  if FCpuFace<>nil then FCpuFace.Send(Value);
  if FGpuFace<>nil then FGpuFace.Send(Value);
end;

procedure TRiderPoseCorrectives.SetBodyParameters(const Value: TRiderBodyParameters);
var Fat, Muscle, Lean: Single; I, J: Integer;
  Shape: TShapeNode; Effect: TX3DNode; Field: TX3DField; Seen: TList;
begin
  if FBody<>nil then FBody.SetBodyParameters(Value);
  if not FBodyContact then Exit;
  RiderBodyShapeWeights(Value, Fat, Muscle, Lean);
  for I := 0 to 2 do
    FContact.Data[I] := FContactCoefficients[I,0] +
      FContactCoefficients[I,1]*Max(0,Fat) +
      FContactCoefficients[I,2]*Max(0,Muscle) +
      FContactCoefficients[I,3]*Max(0,Lean);
  FContact.X := DegToRad(EnsureRange(FContact.X,60,150));
  FContact.Y := Max(FContact.X+DegToRad(10),DegToRad(EnsureRange(FContact.Y,70,170)));
  FContact.Z := EnsureRange(FContact.Z,0,2);
  if not FReady then Exit; { AddUniforms initializes effects created later. }
  { Only a profile edit visits materials. Do not retain fields belonging to
    procedural effects: those effects can be rebuilt/toggled independently. }
  Seen := TList.Create;
  try
    for I := 0 to FSkin.FdShapes.Count-1 do
      if FSkin.FdShapes[I] is TShapeNode then
      begin
        Shape := TShapeNode(FSkin.FdShapes[I]);
        if Shape.Appearance = nil then Continue;
        for J := 0 to Shape.Appearance.FdEffects.Count-1 do
        begin
          Effect := Shape.Appearance.FdEffects[J];
          if (Effect = nil) or (Seen.IndexOf(Effect) >= 0) then Continue;
          Seen.Add(Effect);
          Field := Effect.Field('uRiderPsdContact', False);
          if Field is TSFVec3f then TSFVec3f(Field).Send(FContact);
        end;
      end;
    { The native skinning effect is disabled while procedural skinning is on,
      but must retain the same body profile for a later path switch. }
    if (FCpuEffect <> nil) and (Seen.IndexOf(FCpuEffect) < 0) then
    begin
      Field := FCpuEffect.Field('uRiderPsdContact', False);
      if Field is TSFVec3f then TSFVec3f(Field).Send(FContact);
    end;
  finally Seen.Free end;
end;

function TRiderPoseCorrectives.ShaderSource: string;
begin
  Result := '';
  if FBodyContact then Result := 'uniform vec3 uRiderPsdContact;' + LineEnding;
  Result := Result + 'uniform vec4 uRiderFaceShape;' + LineEnding +
    'attribute vec3 riderPsdSpan;' + LineEnding +
    'uniform sampler2D uRiderPsdAtlas;' + LineEnding +
    'uniform vec2 uRiderPsdSize;' + LineEnding + FWeightsSource +
    'vec4 riderPsdTexel(float id) {' + LineEnding +
    '  return texture2D(uRiderPsdAtlas, (vec2(mod(id,uRiderPsdSize.x),floor(id/uRiderPsdSize.x))+0.5)/uRiderPsdSize);' + LineEnding +
    '}' + LineEnding +
    'void riderPsdOffset(out vec3 dp, out vec3 dn) {' + LineEnding +
    '  dp = vec3(0.0); dn = vec3(0.0);' + LineEnding +
    '  for (int i=0; i<int(riderPsdSpan.y+0.5); i++) {' + LineEnding +
    '    float id = riderPsdSpan.x + float(i)*2.0;' + LineEnding +
    '    vec4 d = riderPsdTexel(id);' + LineEnding +
    '    float w = riderPsdWeight(int(d.w+0.5));' + LineEnding +
    '    dp += d.xyz * w; dn += riderPsdTexel(id+1.0).xyz * w;' + LineEnding +
    '  }' + LineEnding + '}' + LineEnding;
end;

procedure TRiderPoseCorrectives.SetGpuActive(Enabled: Boolean);
begin
  FGpuActive := Enabled;
  if FCpuEffect <> nil then FCpuEffect.Enabled := FNativeSkinActive and not FGpuActive;
  if FBody<>nil then FBody.SendActiveFrame;
end;

procedure TRiderPoseCorrectives.SetNativeSkinActive(Enabled: Boolean);
begin
  { This effect uses CGE's joint palette even when the IK is on the CPU.
    A frozen CPU-baked mesh has no getJointMatrix shader function. }
  FNativeSkinActive := Enabled;
  if FCpuEffect <> nil then FCpuEffect.Enabled := FNativeSkinActive and not FGpuActive;
  if FBody<>nil then FBody.SendActiveFrame;
end;

procedure TRiderPoseCorrectives.UpdateCpuPose;
var J: Integer;
begin
  if not FReady then Exit;
  FAngleList.Clear;
  for J := 0 to FRig.JointCount - 1 do
  begin
    FAngleList.Add(ArcTan2(FRig.Delta[J][6], FRig.Delta[J][10]));
    FAngleList.Add(ArcTan2(-FRig.Delta[J][2], Sqrt(Sqr(FRig.Delta[J][0])+Sqr(FRig.Delta[J][1]))));
    FAngleList.Add(ArcTan2(FRig.Delta[J][1], FRig.Delta[J][0]));
  end;
  FAngles.Send(FAngleList);
end;

end.
