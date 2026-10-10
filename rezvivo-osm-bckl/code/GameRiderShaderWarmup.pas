unit GameRiderShaderWarmup;
{$ifdef ANDROID}{$define OpenGLES}{$endif}
{$mode objfpc}{$H+}

interface

uses CastleViewport, CastleTransform, CastleScene, CastleShapes, CastleGLImages,
  {$ifdef OpenGLES}CastleGLES{$else}CastleGL{$endif}, fpjson;

type
  { A loading-time draw, not a second scene/model. Reuses the exact viewport,
    lights, meshes and shader programs that the ride will use. No pixels are
    read back and no warmup work is performed after the company is ready. }
  TRiderShaderWarmup = class
  private
    FColor, FDepth: TGLRenderToTexture;
    FDepthTexture: TGLTextureId;
    FSelection: TCastleTransformList;
    FModel: TCastleTransform;
    FCamera: TRenderingCamera;
    FPass, FShapeIndex, FVisited, FSelected: Integer;
    FSteps, FDraws: Integer;
    FTotalMs, FMaxMs: QWord;
    procedure ContextClose(Sender: TObject);
    procedure EnsureBuffers;
    function SelectShapes(const Shape: TShape): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    { Actor must be detached. Temporarily attaches it only inside this call,
      renders a bounded batch into a tiny FBO, then detaches in finally. }
    function Step(Viewport: TCastleViewport; Actor, Model: TCastleTransform;
      RiderScene: TCastleScene): Boolean;
    procedure Finish;
    function Diagnostics: TJSONObject;
  end;

implementation

uses SysUtils, Math, CastleVectors, CastleBoxes, CastleRectangles, CastleProjection,
  CastleGLUtils, CastleRenderContext, CastleApplicationProperties;

const
  BufferSize = 32;
  ShapesPerStep = 2;

constructor TRiderShaderWarmup.Create;
begin
  inherited;
  FSelection := TCastleTransformList.Create(False);
  FCamera := TRenderingCamera.Create;
  ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);
end;

destructor TRiderShaderWarmup.Destroy;
begin
  ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);
  ContextClose(nil);
  FCamera.Free;
  FSelection.Free;
  inherited;
end;

procedure TRiderShaderWarmup.ContextClose(Sender: TObject);
begin
  FreeAndNil(FDepth);
  FreeAndNil(FColor);
  if FDepthTexture <> 0 then glDeleteTextures(1, @FDepthTexture);
  FDepthTexture := 0;
  FModel := nil;
  FSelection.Clear;
end;

procedure TRiderShaderWarmup.EnsureBuffers;
var Samples, PreviousTexture: GLint;
begin
  if FColor <> nil then Exit;
  try
  FColor := TGLRenderToTexture.Create(BufferSize, BufferSize);
  FColor.Buffer := tbNone;
  FColor.Stencil := False;
  { Match the actual color pass, including sample-dependent driver variants. }
  glGetIntegerv(GL_SAMPLES, @Samples);
  if (Samples > 1) and GLFeatures.FBOMultiSampling then FColor.MultiSampling := Samples;
  FColor.GLContextOpen;

  glGetIntegerv(GL_TEXTURE_BINDING_2D, @PreviousTexture);
  glGenTextures(1, @FDepthTexture);
  glBindTexture(GL_TEXTURE_2D, FDepthTexture);
  try
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24, BufferSize, BufferSize,
      0, GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, nil);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  finally glBindTexture(GL_TEXTURE_2D, PreviousTexture) end;
  FDepth := TGLRenderToTexture.Create(BufferSize, BufferSize);
  FDepth.Buffer := tbDepth;
  FDepth.Stencil := False;
  FDepth.SetTexture(FDepthTexture, GL_TEXTURE_2D);
  FDepth.GLContextOpen;
  except
    ContextClose(nil);
    raise;
  end;
end;

function TRiderShaderWarmup.SelectShapes(const Shape: TShape): Boolean;
begin
  Result := (FVisited >= FShapeIndex) and (FVisited < FShapeIndex + ShapesPerStep);
  Inc(FVisited);
  if Result then Inc(FSelected);
end;

function TRiderShaderWarmup.Step(Viewport: TCastleViewport;
  Actor, Model: TCastleTransform; RiderScene: TCastleScene): Boolean;
var
  Target: TGLRenderToTexture;
  Box: TBox3D;
  Center, Size: TVector3;
  Extent: Single;
  OldProjection: TMatrix4;
  OldViewport, OldScissor: TRectangle;
  OldDelta: TVector2Integer;
  OldOcclusion, OldMultisample, HadScissor: Boolean;
  OldShapeFilter: TRenderShapeFilter;
  Started: QWord;
begin
  Result := True;
  if (Viewport = nil) or (Actor = nil) or (Model = nil) or
     (GLFeatures = nil) or not GLFeatures.Framebuffer then Exit;
  Assert(Actor.Parent = nil);
  Started := GetTickCount64;
  EnsureBuffers;
  if FModel <> Model then
  begin
    FModel := Model;
    FPass := 0;
    FShapeIndex := 0;
    FSelection.Clear;
    FSelection.Add(Model);
  end;
  if FPass >= 2 then Exit;

  OldViewport := RenderContext.Viewport;
  OldProjection := RenderContext.ProjectionMatrix;
  OldDelta := RenderContext.ViewportDelta;
  HadScissor := RenderContext.FinalScissor(OldScissor);
  OldOcclusion := Viewport.OcclusionCulling;
    {$ifndef OpenGLES}  OldMultisample := glIsEnabled(GL_MULTISAMPLE) <> 0;{$endif}
  OldShapeFilter := nil;
  if RiderScene <> nil then
  begin
    { Warm the near face/hair as well as the distant rider. The camera LOD
      filter otherwise hides the mouth and defers its first draw to the ride.
      Bypassing it also keeps this synthetic camera out of the LOD history. }
    OldShapeFilter := RiderScene.OnRenderShapeFilter;
    RiderScene.OnRenderShapeFilter := nil;
  end;
  Viewport.Items.Add(Actor);
  try
    Box := Model.WorldBoundingBox;
    if Box.IsEmpty then Exit;
    Center := Box.Center;
    Size := Box.Size;
    Extent := Max(1, Max(Size.X, Max(Size.Y, Size.Z)));
    FCamera.FromViewVectors(Center + Vector3(Extent, Extent * 0.6, Extent),
      Vector3(-1, -0.6, -1).Normalize, Vector3(0, 1, 0),
      OrthoProjectionMatrix(FloatRectangle(-Extent, -Extent, Extent * 2, Extent * 2), 0.01, Extent * 6));
    if FPass = 0 then begin Target := FColor; FCamera.Target := rtScreen end
    else begin Target := FDepth; FCamera.Target := rtShadowMap end;
    { Capture through both vertex programs; a reused pose would leave the
      depth program's transform-feedback path uncompiled until the ride. }
    if RiderScene <> nil then Inc(RiderScene.RenderOptions.CachedAnimationRevision);
    FVisited := 0;
    FSelected := 0;
    Viewport.OcclusionCulling := False;
    RenderContext.ScissorDisable;
    RenderContext.ViewportDelta := Vector2Integer(0, 0);
    {$ifndef OpenGLES}    if (FPass = 0) and OldMultisample then glEnable(GL_MULTISAMPLE){$endif}
    {$ifndef OpenGLES}    else glDisable(GL_MULTISAMPLE);{$endif}
    Target.RenderBegin;
    try
      RenderContext.Viewport := Rectangle(0, 0, BufferSize, BufferSize);
      RenderContext.ProjectionMatrix := FCamera.Projection;
      Viewport.InternalRenderSubset(FCamera, FSelection, @SelectShapes);
      { Loading only. Drain deferred compilation here, before physics starts. }
      if FSelected > 0 then glFinish;
    finally Target.RenderEnd end;
    Inc(FShapeIndex, ShapesPerStep);
    if FShapeIndex >= FVisited then begin Inc(FPass); FShapeIndex := 0 end;
    Result := FPass >= 2;
    Inc(FSteps);
    Inc(FDraws, FSelected);
  finally
    Viewport.Items.Remove(Actor);
    if RiderScene <> nil then RiderScene.OnRenderShapeFilter := OldShapeFilter;
    Viewport.OcclusionCulling := OldOcclusion;
    RenderContext.ProjectionMatrix := OldProjection;
    RenderContext.ViewportDelta := OldDelta;
    RenderContext.Viewport := OldViewport;
    if HadScissor then RenderContext.ScissorEnable(OldScissor)
    else RenderContext.ScissorDisable;
    {$ifndef OpenGLES}    if OldMultisample then glEnable(GL_MULTISAMPLE) else glDisable(GL_MULTISAMPLE);{$endif}
    FTotalMs := FTotalMs + GetTickCount64 - Started;
    FMaxMs := Max(FMaxMs, GetTickCount64 - Started);
  end;
end;

procedure TRiderShaderWarmup.Finish;
begin
  ContextClose(nil);
end;

function TRiderShaderWarmup.Diagnostics: TJSONObject;
begin
  Result := TJSONObject.Create(['steps', FSteps, 'draws', FDraws,
    'total_ms', Int64(FTotalMs), 'max_step_ms', Int64(FMaxMs)]);
end;

end.
