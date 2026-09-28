unit RiderPoseCorrectives;

{$mode objfpc}{$H+}

{ Static sparse morph atlas exported alongside an anatomical avatar.
  Both animation paths deform vertices on the GPU. The legacy CPU IK only
  uploads joint angles; the procedural path derives them from its own solve. }
interface

uses Classes, SysUtils, Math, fpjson, jsonparser, CastleUtils, CastleVectors, CastleImages,
  CastleScene, X3DNodes, X3DFields, TripoRig;

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
  public
    NeededJoints: array of Boolean;
    constructor Create;
    destructor Destroy; override;
    function Load(const ModelPath: string; Scene: TCastleScene;
      Skin: TSkinNode; Rig: TTripoRig): Boolean;
    function ShaderSource: string;
    procedure AddUniforms(Effect: TEffectNode);
    procedure SetGpuActive(Enabled: Boolean);
    procedure UpdateCpuPose;
    property Ready: Boolean read FReady;
  end;

implementation

uses GltfCore, RiderCorrectiveData;

constructor TRiderPoseCorrectives.Create;
begin
  inherited;
  FAngleList := TSingleList.Create;
end;

destructor TRiderPoseCorrectives.Destroy;
begin
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
  Root, ShapeInfo, Control, Variables: TJSONObject;
  Shapes, Controls: TJSONArray;
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
  I, K, V, J, Count: Integer;
  Expr: string;
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
    SetLength(NeededJoints, Rig.JointCount);
    Shapes := ArrOf(Root, 'shapes'); Controls := ArrOf(Root, 'controls');
    Lines := TStringList.Create;
    try
      Lines.Add('float riderPsdWeight(int id) {');
      for I := 0 to Controls.Count - 1 do
      begin
        Control := Controls.Objects[I]; Variables := ObjOf(Control, 'variables');
        Lines.Add('  if (id == ' + IntToStr(I) + ') {');
        for K := 0 to Variables.Count - 1 do
        begin
          J := Rig.JointIndexByName(Variables.Items[K].AsString);
          if J < 0 then raise Exception.Create('Missing avatar corrective joint: ' + Variables.Items[K].AsString);
          NeededJoints[J] := True;
          Lines.Add('    float ' + Variables.Names[K] + ' = riderPsdAngle(' + IntToStr(J) + ');');
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
          Attr.FdValue.Items.Add(Span.X);
          Attr.FdValue.Items.Add(Span.Y);
          Attr.FdValue.Items.Add(Span.Z);
        end;
        Geom.FdAttrib.Add(Attr);
      end;
      if FileData.Position <> FileData.Size then raise Exception.Create('Avatar corrective data size mismatch');
    finally Pixels.Free end;

    FCpuEffect := TEffectNode.Create('RiderCpuPoseCorrectives');
    FCpuEffect.KeepExistingBegin;
    FCpuEffect.Language := slGLSL;
    FCpuEffect.InternalCacheVertexAnimation := True;
    FAngles := TMFFloat.Create(FCpuEffect, True, 'uRiderPsdAngles', []);
    for I := 0 to Rig.JointCount - 1 do FAngles.Items.Add(0);
    FCpuEffect.AddCustomField(FAngles);
    AddUniforms(FCpuEffect);
    Part := TEffectPartNode.Create;
    Part.FdType.Value := 'VERTEX';
    Part.Contents := 'mat4 skinMatrix;' + LineEnding +
      'uniform float uRiderPsdAngles[' + IntToStr(Rig.JointCount) + '];' + LineEnding +
      'float riderPsdAngle(int j) { return uRiderPsdAngles[j]; }' + LineEnding + ShaderSource +
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
var TextureField: TSFNode;
begin
  TextureField := TSFNode.Create(Effect, True, 'uRiderPsdAtlas', [TImageTextureNode]);
  TextureField.Value := FTexture;
  Effect.AddCustomField(TextureField);
  Effect.AddCustomField(TSFVec2f.Create(Effect, True, 'uRiderPsdSize', Vector2(FWidth, FHeight)));
end;

function TRiderPoseCorrectives.ShaderSource: string;
begin
  Result := 'attribute vec3 riderPsdSpan;' + LineEnding +
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
  if FCpuEffect <> nil then FCpuEffect.Enabled := not Enabled;
end;

procedure TRiderPoseCorrectives.UpdateCpuPose;
var J: Integer;
begin
  if not FReady then Exit;
  FAngleList.Clear;
  for J := 0 to FRig.JointCount - 1 do
    FAngleList.Add(ArcTan2(FRig.Delta[J][6], FRig.Delta[J][10]));
  FAngles.Send(FAngleList);
end;

end.
