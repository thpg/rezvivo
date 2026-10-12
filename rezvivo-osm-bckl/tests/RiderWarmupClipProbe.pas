program RiderWarmupClipProbe;
{$mode objfpc}{$H+}
{ Hidden GL regression: warming a rider inside a clipped settings panel must
  not turn that panel's clip into a permanent window scissor. }
uses SysUtils, CastleWindow, CastleViewport, CastleScene, CastleTransform,
  CastleVectors, CastleRectangles, CastleRenderContext, CastleGL,
  CastleGLImages, CastleImages, CastleLog, CastleApplicationProperties,
  X3DNodes, GameRiderShaderWarmup;

var Window:TCastleWindow; Viewport:TCastleViewport; Camera:TCastleCamera;
  Actor:TCastleTransform; Scene:TCastleScene; Warmup:TRiderShaderWarmup;
  Root:TX3DRootNode; Shape:TShapeNode; ParentClip:TScissor;
  R:TRectangle; Img:TRGBImage; OutputDir:String; Failure:String;

procedure Check(Value:Boolean;const Msg:String);
begin if not Value then raise Exception.Create(Msg) end;

procedure RunCase(const Name:String;GlobalClip,NestedClip:Boolean);
var Expected:TRectangle;HadClip:Boolean;Box:array[0..3]of GLint;
begin
  RenderContext.ScissorDisable;
  glClearColor(0.8,0.05,0.02,1);glClear(GL_COLOR_BUFFER_BIT);
  if GlobalClip then RenderContext.ScissorEnable(Rectangle(16,16,224,224));
  ParentClip:=TScissor.Create;
  try
    if NestedClip then begin
      ParentClip.Rect:=Rectangle(64,24,176,168);ParentClip.Enabled:=True;
    end;
    HadClip:=RenderContext.FinalScissor(Expected);
    Warmup:=TRiderShaderWarmup.Create;
    try
      Warmup.Step(Viewport,Actor,Scene,Scene);
      Warmup.Step(Viewport,Actor,Scene,Scene);
      Check((glIsEnabled(GL_SCISSOR_TEST)<>0)=HadClip,Name+': raw scissor enabled state changed');
      if HadClip then begin
        glGetIntegerv(GL_SCISSOR_BOX,@Box[0]);
        Check((Box[0]=Expected.Left)and(Box[1]=Expected.Bottom)and
          (Box[2]=Expected.Width)and(Box[3]=Expected.Height),Name+': raw scissor rectangle changed');
      end;
    finally FreeAndNil(Warmup) end;
  finally FreeAndNil(ParentClip) end;
  { Clear the actual back buffer, without SaveScreen's extra render: a stale
    clip leaves exactly the old panel's top/left strips unpainted. }
  glClearColor(0.05,0.25,0.9,1);glClear(GL_COLOR_BUFFER_BIT);
  Img:=SaveScreen_NoFlush(Rectangle(0,0,256,256),cbBack);
  try SaveImage(Img,OutputDir+Name+'.png');finally Img.Free end;
  Check(RenderContext.FinalScissor(R)=GlobalClip,Name+': parent clip leaked into global scissor');
  if GlobalClip then
    Check((R.Left=16)and(R.Bottom=16)and(R.Width=224)and(R.Height=224),Name+': original global clip replaced');
  Check((glIsEnabled(GL_SCISSOR_TEST)<>0)=GlobalClip,Name+': GL scissor remains after panel removal');
  Check(glGetError()=GL_NO_ERROR,Name+': GL error');
end;

begin
  if ParamCount<>1 then raise Exception.Create('Expected output directory');
  OutputDir:=IncludeTrailingPathDelimiter(ExpandFileName(ParamStr(1)));ForceDirectories(OutputDir);
  ApplicationProperties.ApplicationName:='REZVIVOWarmupClipProbe';
  LogFileName:=OutputDir+'probe.log';InitializeLog;
  Window:=TCastleWindow.Create(nil);
  try
    Window.Visible:=False;Window.Width:=256;Window.Height:=256;
    Viewport:=TCastleViewport.Create(Window);Viewport.FullSize:=True;
    Window.Controls.InsertFront(Viewport);
    Camera:=TCastleCamera.Create(Window);Viewport.Items.Add(Camera);Viewport.Camera:=Camera;
    Camera.SetView(Vector3(0,1,5),Vector3(0,0,-1),Vector3(0,1,0));
    Actor:=TCastleTransform.Create(Window);Scene:=TCastleScene.Create(Window);Actor.Add(Scene);
    Root:=TX3DRootNode.Create;Shape:=TShapeNode.Create;Shape.Geometry:=TBoxNode.Create;
    Root.AddChildren(Shape);Scene.Load(Root,True);Window.Open;
    try
      RunCase('no-clip',False,False);
      RunCase('panel-clip',False,True);
      RunCase('global-and-panel',True,True);
      Writeln('PASS: warmup preserves raw GL and logical nested/global scissors');
    except on E:Exception do begin Failure:=E.Message;Writeln('FAIL: ',Failure);ExitCode:=1 end end;
    RenderContext.ScissorDisable;
  finally Window.Free end;
end.
