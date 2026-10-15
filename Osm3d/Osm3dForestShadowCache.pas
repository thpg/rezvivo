unit Osm3dForestShadowCache;
{$ifdef ANDROID}{$define OpenGLES}{$endif}
{$mode objfpc}{$H+}
interface
uses CastleVectors, CastleTransform, CastleViewport, CastleRenderOptions,
  X3DNodes, fpjson;
type
  { Reusable projected depth storage. Compositing writes nearest depth into
    the existing atlas, so receivers still sample a single shadow texture. }
  TShadowDepthCache = class
  protected
    FMap:TGeneratedShadowMapNode;
    FLight:TDirectionalLightNode;
    FOptions:TCastleRenderOptions;
    FValid:Boolean;
    FDirection:TVector3;
    FX,FY,FHalf,FNear,FFar:Single;
    FCaptures:QWord;
    FProgram,FVAO:Cardinal;
    FSampler,FRemap,FDepthRemap,FSourceCount:LongInt;
    procedure InitializeProgram;
    procedure CaptureDepth(const Render:TRenderFromViewFunction;const Side,Up:TVector3);
  public
    constructor Create;
    destructor Destroy;override;
    procedure ContextClose;
    procedure Invalidate;
    function Covers(const Direction:TVector3;X,Y,Half,MinDepth,MaxDepth:Single):Boolean;
    function SameTexelSize(Half:Single;TileSize:Integer):Boolean;
    procedure CaptureRegion(const Render:TRenderFromViewFunction;
      const Direction,Side,Up:TVector3;X,Y,Half,MinDepth,MaxDepth:Single;
      TileSize:Integer);
    procedure Draw(X,Y,Half,MinDepth,MaxDepth:Single);
    procedure DrawSource(Source:TShadowDepthCache;X,Y,Half,MinDepth,MaxDepth:Single);
    procedure DrawSources(const Sources:array of TShadowDepthCache;X,Y,Half,MinDepth,MaxDepth:Single);
    function StorageBytes:Int64;
    property Ready:Boolean read FValid;
  end;
  { One light-space depth image for the entire distant forest, not one
    silhouette per tree. Only the outer receiver cascade uses this image. }
  TForestShadowCache = class(TShadowDepthCache)
  private
    FViewport:TCastleViewport;
    FCasters:TCastleTransformList;
    FPrefetchOffset:TVector3;
    FRevision,FLastCapture,FReuses:QWord;
    procedure Capture(const Camera:TRenderingCamera);
  public
    constructor Create;
    destructor Destroy;override;
    procedure Prepare(Viewport:TCastleViewport;Casters:TCastleTransformList;
      Revision:QWord;const Direction,Side,Up:TVector3;
      X,Y,Half,MinDepth,MaxDepth:Single;Size:Integer);
    procedure Snapshot(J:TJSONObject);
    property PrefetchOffset:TVector3 read FPrefetchOffset write FPrefetchOffset;
  end;
function ShadowDepthFragmentSource(ForES:Boolean):AnsiString;
implementation
uses SysUtils,Math,CastleInternalRenderer,
  {$ifdef OpenGLES}CastleGLES,RenderGLES{$else}CastleGL{$endif};

constructor TShadowDepthCache.Create;
begin
  inherited;
  FOptions:=TCastleRenderOptions.Create(nil);
  FLight:=TDirectionalLightNode.Create;FLight.KeepExistingBegin;
  FMap:=TGeneratedShadowMapNode.Create;FMap.KeepExistingBegin;
  FMap.X3DName:='CachedWorldDepth';FMap.Light:=FLight;
  FMap.FdScale.Value:=1;FMap.FdBias.Value:=1;
end;

procedure TShadowDepthCache.ContextClose;
begin
  FValid:=False;
  TTextureResources.Unprepare(FMap);
  if FProgram<>0 then glDeleteProgram(FProgram);FProgram:=0;
  if FVAO<>0 then glDeleteVertexArrays(1,@FVAO);FVAO:=0;
end;

destructor TShadowDepthCache.Destroy;
begin
  ContextClose;
  FMap.KeepExistingEnd;FMap.FreeIfUnused;
  FLight.KeepExistingEnd;FLight.FreeIfUnused;
  FOptions.Free;
  inherited;
end;

procedure TShadowDepthCache.Invalidate;
begin FValid:=False;end;

function TShadowDepthCache.StorageBytes:Int64;
begin
  { D24 storage is normally aligned to 32 bits on desktop GPUs. }
  if TTextureResources.Get(FMap)=nil then Exit(0);
  Result:=Int64(FMap.Size)*FMap.Size*4;
end;

function TShadowDepthCache.Covers(const Direction:TVector3;
  X,Y,Half,MinDepth,MaxDepth:Single):Boolean;
begin
  Result:=FValid and ((FDirection-Direction).Length<0.0001) and
    (Abs(X-FX)+Half<FHalf-0.01) and (Abs(Y-FY)+Half<FHalf-0.01) and
    (MinDepth>=FNear) and (MaxDepth<=FFar);
end;

function TShadowDepthCache.SameTexelSize(Half:Single;TileSize:Integer):Boolean;
begin
  Result:=Abs(FHalf/FMap.Size-Half/TileSize)<Max(0.000001,Half/TileSize*0.0001);
end;

procedure TShadowDepthCache.CaptureDepth(const Render:TRenderFromViewFunction;
  const Side,Up:TVector3);
var Hint:TVector3;
begin
  FValid:=False;
  Hint:=Vector3(0,1,0);if Abs(FDirection.Y)>0.99 then Hint:=Vector3(0,0,1);
  FLight.Direction:=FDirection;FLight.Up:=Hint;
  FLight.FdProjectionLocation.Value:=Side*FX+Up*FY+FDirection*FNear;
  FLight.FdProjectionRectangle.Value:=Vector4(-FHalf,-FHalf,FHalf,FHalf);
  FLight.FdProjectionNear.Value:=0.1;FLight.FdProjectionFar.Value:=FFar-FNear;
  TTextureResources.Prepare(FOptions,FMap);
  TGeneratedShadowMapResource(TTextureResources.Get(FMap)).UpdateRegion(
    Render,FLight,0,0,FMap.Size,FMap.Size);
  FValid:=True;Inc(FCaptures);
end;

procedure TShadowDepthCache.CaptureRegion(const Render:TRenderFromViewFunction;
  const Direction,Side,Up:TVector3;X,Y,Half,MinDepth,MaxDepth:Single;TileSize:Integer);
var Size:Integer;Step:Single;
begin
  { Add a guard band WITHOUT enlarging the shadow texel. Exactly the same
    light-space grid as the live cascade avoids spatial quality loss. }
  Size:=TileSize+TileSize div 4;
  if FMap.Size<>Size then begin TTextureResources.Unprepare(FMap);FMap.Size:=Size;end;
  Step:=2*Half/TileSize;
  FX:=Round(X/Step)*Step;FY:=Round(Y/Step)*Step;
  FHalf:=Step*Size*0.5;FDirection:=Direction;
  FNear:=Floor((MinDepth-16)/16)*16;FFar:=Ceil((MaxDepth+16)/16)*16;
  CaptureDepth(Render,Side,Up);
end;

constructor TForestShadowCache.Create;
begin inherited;FCasters:=TCastleTransformList.Create(False);end;

destructor TForestShadowCache.Destroy;
begin FCasters.Free;inherited;end;

procedure TForestShadowCache.Capture(const Camera:TRenderingCamera);
begin
  FViewport.InternalRenderShadowCasters(Camera,FCasters,nil);
end;

procedure TForestShadowCache.Prepare(Viewport:TCastleViewport;Casters:TCastleTransformList;
  Revision:QWord;const Direction,Side,Up:TVector3;
  X,Y,Half,MinDepth,MaxDepth:Single;Size:Integer);
var Padding,Grid,LeadX,LeadY:Single;Tick:QWord;I:Integer;
begin
  Tick:=GetTickCount64;
  { Guard band lets the camera move without resampling geometry. Reprojection
    below uses depth too, so slopes and overlapping crowns retain their height. }
  Padding:=Max(12,Half*0.125);Grid:=Padding*0.5;
  { Spend existing guard space in the direction of travel. The footprint,
    texture size and capture count per frame remain bounded as before. }
  LeadX:=EnsureRange(TVector3.DotProduct(Side,FPrefetchOffset),-Padding*0.4,Padding*0.4);
  LeadY:=EnsureRange(TVector3.DotProduct(Up,FPrefetchOffset),-Padding*0.4,Padding*0.4);
  if FValid and (FMap.Size=Size) and ((FDirection-Direction).Length<0.0001) and
    (Abs(X+LeadX*0.5-FX)+Half<FHalf-1) and (Abs(Y+LeadY*0.5-FY)+Half<FHalf-1) and
    (Abs(X-FX)+Half<FHalf-1) and (Abs(Y-FY)+Half<FHalf-1) and
    (MinDepth>=FNear) and (MaxDepth<=FFar) and
    ((Revision=FRevision) or (Tick-FLastCapture<1000)) then
  begin Inc(FReuses);Exit end;
  if FMap.Size<>Size then begin TTextureResources.Unprepare(FMap);FMap.Size:=Size;end;
  FValid:=False;FX:=Round((X+LeadX)/Grid)*Grid;FY:=Round((Y+LeadY)/Grid)*Grid;
  FHalf:=Ceil((Half+Padding)/Grid)*Grid;
  FNear:=Floor((MinDepth-16)/16)*16;FFar:=Ceil((MaxDepth+16)/16)*16;
  FDirection:=Direction;
  FCasters.Clear;
  for I:=0 to Casters.Count-1 do FCasters.Add(Casters[I]);
  FViewport:=Viewport;
  try
    CaptureDepth(@Capture,Side,Up);
    FRevision:=Revision;FLastCapture:=Tick;
  finally FViewport:=nil;FCasters.Clear end;
end;

function ShadowDepthFragmentSource(ForES:Boolean):AnsiString;
var I:Integer;
begin
  if ForES then Result:='#version 300 es'#10'precision highp float;precision highp int;precision highp sampler2D;'#10
  else Result:='#version 330'#10;
  Result:=Result+'in vec2 uv;uniform sampler2D depths[5];uniform vec4 remap[5];'+
    'uniform vec2 depthRemap[5];uniform int sourceCount;'+
    'float readDepth(sampler2D tex,vec4 r,vec2 dz){vec2 p=uv*r.xy+r.zw;'+
    'if(any(lessThan(p,vec2(0)))||any(greaterThan(p,vec2(1))))return 1.;'+
    'float d=texture(tex,p).r;if(d>=1.)return 1.;float z=d*dz.x+dz.y;'+
    'return (z<0.||z>1.)?1.:z;}void main(){float z=1.;';
  { Constant sampler indices also compile on GLES 3.0. Dynamic sampler-array
    indexing would unnecessarily require a newer mobile shading language. }
  for I:=0 to 4 do Result:=Result+'if(sourceCount>'+IntToStr(I)+')z=min(z,readDepth(depths['+
    IntToStr(I)+'],remap['+IntToStr(I)+'],depthRemap['+IntToStr(I)+']));';
  Result:=Result+'if(z>=1.)discard;gl_FragDepth=z;}';
end;

procedure TShadowDepthCache.InitializeProgram;
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
    FS:=Shader(GL_FRAGMENT_SHADER,ShadowDepthFragmentSource({$ifdef OpenGLES}True{$else}False{$endif}));
    try
      FProgram:=glCreateProgram();glAttachShader(FProgram,VS);glAttachShader(FProgram,FS);
      glLinkProgram(FProgram);glGetProgramiv(FProgram,GL_LINK_STATUS,@OK);
      if OK=0 then begin glDeleteProgram(FProgram);FProgram:=0;raise Exception.Create('Forest shadow cache link failed');end;
    finally glDeleteShader(FS) end;
  finally glDeleteShader(VS) end;
  glGenVertexArrays(1,@FVAO);
  FSampler:=glGetUniformLocation(FProgram,'depths[0]');
  FRemap:=glGetUniformLocation(FProgram,'remap[0]');
  FDepthRemap:=glGetUniformLocation(FProgram,'depthRemap[0]');
  FSourceCount:=glGetUniformLocation(FProgram,'sourceCount');
end;

procedure TShadowDepthCache.Draw(X,Y,Half,MinDepth,MaxDepth:Single);
begin DrawSource(Self,X,Y,Half,MinDepth,MaxDepth);end;

procedure TShadowDepthCache.DrawSource(Source:TShadowDepthCache;X,Y,Half,MinDepth,MaxDepth:Single);
begin DrawSources([Source],X,Y,Half,MinDepth,MaxDepth);end;

procedure TShadowDepthCache.DrawSources(const Sources:array of TShadowDepthCache;X,Y,Half,MinDepth,MaxDepth:Single);
var OldProgram,OldVAO,OldActive,OldFunc:GLint;
    OldTexture,OldCompare,OldMinFilter,OldMagFilter,Units:array[0..4]of GLint;
    Textures:array[0..4]of Cardinal;
    Remaps:array[0..4,0..3]of Single;Depths:array[0..4,0..1]of Single;
    WasDepth,WasCull,WasBlend,OldWrite:GLBoolean;Mask:array[0..3]of GLBoolean;
    Source:TShadowDepthCache;Span:Single;I,N:Integer;
begin
  N:=0;Span:=MaxDepth-MinDepth-0.1;
  if Span<=0 then Exit;
  for Source in Sources do if (Source<>nil) and Source.FValid then begin
    if N=5 then raise EArgumentException.Create('At most five shadow depth sources');
    Textures[N]:=TGeneratedShadowMapResource(TTextureResources.Get(Source.FMap)).GLName;
    Remaps[N,0]:=Half/Source.FHalf;Remaps[N,1]:=Half/Source.FHalf;
    Remaps[N,2]:=(X-Half-Source.FX+Source.FHalf)/(2*Source.FHalf);
    Remaps[N,3]:=(Y-Half-Source.FY+Source.FHalf)/(2*Source.FHalf);
    Depths[N,0]:=(Source.FFar-Source.FNear-0.1)/Span;
    Depths[N,1]:=(Source.FNear-MinDepth)/Span;
    Inc(N);
  end;
  if N=0 then Exit;
  InitializeProgram;
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ACTIVE_TEXTURE,@OldActive);glGetIntegerv(GL_DEPTH_FUNC,@OldFunc);
  glGetBooleanv(GL_DEPTH_WRITEMASK,@OldWrite);glGetBooleanv(GL_COLOR_WRITEMASK,@Mask[0]);
  WasDepth:=glIsEnabled(GL_DEPTH_TEST);WasCull:=glIsEnabled(GL_CULL_FACE);WasBlend:=glIsEnabled(GL_BLEND);
  for I:=0 to 4 do Units[I]:=Min(I,N-1);
  for I:=0 to N-1 do begin
    glActiveTexture(GL_TEXTURE0+I);glGetIntegerv(GL_TEXTURE_BINDING_2D,@OldTexture[I]);
    glBindTexture(GL_TEXTURE_2D,Textures[I]);
    glGetTexParameteriv(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,@OldCompare[I]);
    glGetTexParameteriv(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,@OldMinFilter[I]);
    glGetTexParameteriv(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,@OldMagFilter[I]);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,GL_NONE);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
  end;
  try
    glEnable(GL_DEPTH_TEST);glDepthFunc(GL_LESS);glDepthMask(GL_TRUE);
    glDisable(GL_CULL_FACE);glDisable(GL_BLEND);glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);
    glUseProgram(FProgram);glBindVertexArray(FVAO);
    glUniform1iv(FSampler,5,@Units[0]);glUniform1i(FSourceCount,N);
    glUniform4fv(FRemap,N,@Remaps[0,0]);glUniform2fv(FDepthRemap,N,@Depths[0,0]);
    glDrawArrays(GL_TRIANGLES,0,3);
  finally
    for I:=N-1 downto 0 do begin
      glActiveTexture(GL_TEXTURE0+I);
      glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,OldCompare[I]);
      glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,OldMinFilter[I]);
      glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,OldMagFilter[I]);
      glBindTexture(GL_TEXTURE_2D,OldTexture[I]);
    end;
    glActiveTexture(OldActive);
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
