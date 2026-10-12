unit Osm3dForestShadowCache;
{$ifdef ANDROID}{$define OpenGLES}{$endif}
{$mode objfpc}{$H+}
interface
uses CastleVectors, CastleTransform, CastleViewport, CastleRenderOptions,
  X3DNodes, fpjson;
type
  { One light-space depth image for the entire distant forest, not one
    silhouette per tree. Only the outer receiver cascade uses this image. }
  TForestShadowCache = class
  private
    FMap:TGeneratedShadowMapNode;
    FLight:TDirectionalLightNode;
    FOptions:TCastleRenderOptions;
    FViewport:TCastleViewport;
    FCasters:TCastleTransformList;
    FValid:Boolean;
    FDirection:TVector3;
    FX,FY,FHalf,FNear,FFar:Single;
    FRevision,FLastCapture,FCaptures,FReuses:QWord;
    FProgram,FVAO:Cardinal;
    procedure Capture(const Camera:TRenderingCamera);
    procedure InitializeProgram;
  public
    constructor Create;
    destructor Destroy;override;
    procedure ContextClose;
    procedure Prepare(Viewport:TCastleViewport;Casters:TCastleTransformList;
      Revision:QWord;const Direction,Side,Up:TVector3;
      X,Y,Half,MinDepth,MaxDepth:Single;Size:Integer);
    procedure Draw(X,Y,Half,MinDepth,MaxDepth:Single);
    procedure Snapshot(J:TJSONObject);
    property Ready:Boolean read FValid;
  end;
implementation
uses SysUtils,Math,CastleInternalRenderer,
  {$ifdef OpenGLES}CastleGLES,RenderGLES{$else}CastleGL{$endif};

constructor TForestShadowCache.Create;
begin
  inherited;
  FOptions:=TCastleRenderOptions.Create(nil);
  FCasters:=TCastleTransformList.Create(False);
  FLight:=TDirectionalLightNode.Create;FLight.KeepExistingBegin;
  FMap:=TGeneratedShadowMapNode.Create;FMap.KeepExistingBegin;
  FMap.X3DName:='DistantForestGroupDepth';FMap.Light:=FLight;
  FMap.FdScale.Value:=1;FMap.FdBias.Value:=1;
end;

procedure TForestShadowCache.ContextClose;
begin
  FValid:=False;
  TTextureResources.Unprepare(FMap);
  if FProgram<>0 then glDeleteProgram(FProgram);FProgram:=0;
  if FVAO<>0 then glDeleteVertexArrays(1,@FVAO);FVAO:=0;
end;

destructor TForestShadowCache.Destroy;
begin
  ContextClose;
  FMap.KeepExistingEnd;FMap.FreeIfUnused;
  FLight.KeepExistingEnd;FLight.FreeIfUnused;
  FCasters.Free;FOptions.Free;
  inherited;
end;

procedure TForestShadowCache.Capture(const Camera:TRenderingCamera);
begin
  FViewport.InternalRenderShadowCasters(Camera,FCasters,nil);
end;

procedure TForestShadowCache.Prepare(Viewport:TCastleViewport;Casters:TCastleTransformList;
  Revision:QWord;const Direction,Side,Up:TVector3;
  X,Y,Half,MinDepth,MaxDepth:Single;Size:Integer);
var Padding,Grid:Single;Tick:QWord;I:Integer;Hint:TVector3;
begin
  Tick:=GetTickCount64;
  { Guard band lets the camera move without resampling geometry. Reprojection
    below uses depth too, so slopes and overlapping crowns retain their height. }
  Padding:=Max(12,Half*0.125);Grid:=Padding*0.5;
  if FValid and (FMap.Size=Size) and ((FDirection-Direction).Length<0.0001) and
    (Abs(X-FX)+Half<FHalf-1) and (Abs(Y-FY)+Half<FHalf-1) and
    (MinDepth>=FNear) and (MaxDepth<=FFar) and
    ((Revision=FRevision) or (Tick-FLastCapture<1000)) then
  begin Inc(FReuses);Exit end;
  if FMap.Size<>Size then begin TTextureResources.Unprepare(FMap);FMap.Size:=Size;end;
  FValid:=False;FX:=Round(X/Grid)*Grid;FY:=Round(Y/Grid)*Grid;
  FHalf:=Ceil((Half+Padding)/Grid)*Grid;
  FNear:=Floor((MinDepth-16)/16)*16;FFar:=Ceil((MaxDepth+16)/16)*16;
  FDirection:=Direction;
  Hint:=Vector3(0,1,0);if Abs(Direction.Y)>0.99 then Hint:=Vector3(0,0,1);
  FLight.Direction:=Direction;FLight.Up:=Hint;
  FLight.FdProjectionLocation.Value:=Side*FX+Up*FY+Direction*FNear;
  FLight.FdProjectionRectangle.Value:=Vector4(-FHalf,-FHalf,FHalf,FHalf);
  FLight.FdProjectionNear.Value:=0.1;FLight.FdProjectionFar.Value:=FFar-FNear;
  FCasters.Clear;
  for I:=0 to Casters.Count-1 do FCasters.Add(Casters[I]);
  FViewport:=Viewport;
  try
    TTextureResources.Prepare(FOptions,FMap);
    TGeneratedShadowMapResource(TTextureResources.Get(FMap)).UpdateRegion(
      @Capture,FLight,0,0,Size,Size);
    FValid:=True;FRevision:=Revision;FLastCapture:=Tick;Inc(FCaptures);
  finally FViewport:=nil;FCasters.Clear end;
end;

procedure TForestShadowCache.InitializeProgram;
const
  {$ifdef OpenGLES}Header='#version 300 es'#10'precision highp float;'#10;
  {$else}Header='#version 330'#10;{$endif}
var VS,FS:Cardinal;OK:GLint;
  function Shader(Kind:Cardinal;const Source:AnsiString):Cardinal;
  var P:PGLchar;N,Status:GLint;Msg:array[0..2047]of AnsiChar;
  begin
    Result:=glCreateShader(Kind);P:=PGLchar(Source);N:=Length(Source);
    glShaderSource(Result,1,@P,@N);glCompileShader(Result);
    glGetShaderiv(Result,GL_COMPILE_STATUS,@Status);
    if Status=0 then begin
      glGetShaderInfoLog(Result,SizeOf(Msg),nil,@Msg[0]);glDeleteShader(Result);
      raise Exception.Create('Forest shadow cache shader: '+string(PAnsiChar(@Msg[0])));
    end;
  end;
begin
  if FProgram<>0 then Exit;
  VS:=Shader(GL_VERTEX_SHADER,Header+
    'out vec2 uv;void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);uv=p;gl_Position=vec4(p*2.-1.,0.,1.);}');
  try
    FS:=Shader(GL_FRAGMENT_SHADER,Header+
      'in vec2 uv;uniform sampler2D forest;uniform vec4 remap;uniform vec2 depthRemap;'+
      'void main(){vec2 p=uv*remap.xy+remap.zw;if(any(lessThan(p,vec2(0)))||any(greaterThan(p,vec2(1))))discard;'+
      'float d=texture(forest,p).r;if(d>=1.)discard;float z=d*depthRemap.x+depthRemap.y;'+
      'if(z<0.||z>1.)discard;gl_FragDepth=z;}');
    try
      FProgram:=glCreateProgram();glAttachShader(FProgram,VS);glAttachShader(FProgram,FS);
      glLinkProgram(FProgram);glGetProgramiv(FProgram,GL_LINK_STATUS,@OK);
      if OK=0 then begin glDeleteProgram(FProgram);FProgram:=0;raise Exception.Create('Forest shadow cache link failed');end;
    finally glDeleteShader(FS) end;
  finally glDeleteShader(VS) end;
  glGenVertexArrays(1,@FVAO);
end;

procedure TForestShadowCache.Draw(X,Y,Half,MinDepth,MaxDepth:Single);
var OldProgram,OldVAO,OldActive,OldTexture,OldFunc,OldCompare,OldMinFilter,OldMagFilter:GLint;
    WasDepth,WasCull,WasBlend,OldWrite:GLBoolean;Mask:array[0..3]of GLBoolean;
    Texture:Cardinal;Span:Single;
begin
  if not FValid then Exit;
  InitializeProgram;
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ACTIVE_TEXTURE,@OldActive);glActiveTexture(GL_TEXTURE0);
  glGetIntegerv(GL_TEXTURE_BINDING_2D,@OldTexture);glGetIntegerv(GL_DEPTH_FUNC,@OldFunc);
  glGetBooleanv(GL_DEPTH_WRITEMASK,@OldWrite);glGetBooleanv(GL_COLOR_WRITEMASK,@Mask[0]);
  WasDepth:=glIsEnabled(GL_DEPTH_TEST);WasCull:=glIsEnabled(GL_CULL_FACE);WasBlend:=glIsEnabled(GL_BLEND);
  Texture:=TGeneratedShadowMapResource(TTextureResources.Get(FMap)).GLName;
  glBindTexture(GL_TEXTURE_2D,Texture);glGetTexParameteriv(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,@OldCompare);
  glGetTexParameteriv(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,@OldMinFilter);
  glGetTexParameteriv(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,@OldMagFilter);
  try
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,GL_NONE);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glEnable(GL_DEPTH_TEST);glDepthFunc(GL_LESS);glDepthMask(GL_TRUE);
    glDisable(GL_CULL_FACE);glDisable(GL_BLEND);glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);
    glUseProgram(FProgram);glBindVertexArray(FVAO);
    glUniform1i(glGetUniformLocation(FProgram,'forest'),0);
    glUniform4f(glGetUniformLocation(FProgram,'remap'),Half/FHalf,Half/FHalf,
      (X-Half-FX+FHalf)/(2*FHalf),(Y-Half-FY+FHalf)/(2*FHalf));
    Span:=MaxDepth-MinDepth-0.1;
    glUniform2f(glGetUniformLocation(FProgram,'depthRemap'),(FFar-FNear-0.1)/Span,(FNear-MinDepth)/Span);
    glDrawArrays(GL_TRIANGLES,0,3);
  finally
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,OldCompare);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,OldMinFilter);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,OldMagFilter);
    glBindTexture(GL_TEXTURE_2D,OldTexture);glActiveTexture(OldActive);
    glUseProgram(OldProgram);glBindVertexArray(OldVAO);glDepthFunc(OldFunc);glDepthMask(OldWrite);
    glColorMask(Mask[0],Mask[1],Mask[2],Mask[3]);
    if WasDepth=GL_TRUE then glEnable(GL_DEPTH_TEST) else glDisable(GL_DEPTH_TEST);
    if WasCull=GL_TRUE then glEnable(GL_CULL_FACE) else glDisable(GL_CULL_FACE);
    if WasBlend=GL_TRUE then glEnable(GL_BLEND) else glDisable(GL_BLEND);
  end;
end;

procedure TForestShadowCache.Snapshot(J:TJSONObject);
begin
  J.Add('far_forest_ready',FValid);J.Add('far_forest_captures',Int64(FCaptures));
  J.Add('far_forest_reuses',Int64(FReuses));J.Add('far_forest_size',FMap.Size);
  J.Add('far_forest_half_extent',FHalf);J.Add('live_tree_cascades',3);
end;
end.
