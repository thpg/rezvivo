program UnpavedRoadVisualProbe;
{$mode objfpc}{$H+}
{ Render the production ground material, atlas and road-page cache, hidden.
  Road/land vertices share positions, as they do after the terrain carve. }
uses SysUtils, Math, CastleWindow, CastleViewport, CastleScene, CastleCameras,
  CastleVectors, CastleImages, CastleLog, CastleApplicationProperties,
  CastleFilesUtils, CastleGL, CastleTimeUtils, CastleTransform, X3DNodes, X3DFields,
  Osm3dGeomMesh, Osm3dGroundComposite, Osm3dSceneAssembler,
  Osm3dRoadSurfaceBinding, Osm3dRoadSurface, Osm3dRoadMaterial, Osm3dTileX3D,
  Osm3dRenderProfile, RenderComplexity;
var Window: TCastleWindow; Viewport: TCastleViewport; Camera: TCastleCamera;
  Atlas: TGroundAtlas; Scene: TCastleScene; Root: TX3DRootNode; Shape: TShapeNode;
  Comp: TGroundCompositeMesh; Model: TTileModel; Seg: TTileRoadSeg;
  OutDir, Prefix: string; Kind, Quality, I, View, BackMat: Integer;
  Query:GLuint;Nanos,TotalNanos:QWord;
  Image: TRGBImage; Start: TTimerResult; Elapsed: Double;
const RoadWidth=4.8;
function Center(Z:Single):Single;
begin Result:=2.6*Sin(Z*0.065) end;
procedure Strip(X0,X1,Z0,Z1:Single; Mat:Integer; Owner:Int64; U0,U1:Single);
var V:TMeshVertex; N:Integer;
begin
  N:=Comp.VertexCount;V:=Default(TMeshVertex);V.Normal:=Vector3(0,1,0);V.OsmId:=Owner;
  V.Position:=Vector3(Center(Z0)+X0,0,Z0);V.UV:=Vector2(U0,Z0/6);
  if Owner=0 then V.UV:=Vector2(V.Position.X,V.Position.Z)/GROUND_MATERIALS[Mat].UVScale;
  Comp.AppendVertex(V,Mat);
  V.Position:=Vector3(Center(Z0)+X1,0,Z0);V.UV:=Vector2(U1,Z0/6);
  if Owner=0 then V.UV:=Vector2(V.Position.X,V.Position.Z)/GROUND_MATERIALS[Mat].UVScale;
  Comp.AppendVertex(V,Mat);
  V.Position:=Vector3(Center(Z1)+X0,0,Z1);V.UV:=Vector2(U0,Z1/6);
  if Owner=0 then V.UV:=Vector2(V.Position.X,V.Position.Z)/GROUND_MATERIALS[Mat].UVScale;
  Comp.AppendVertex(V,Mat);
  V.Position:=Vector3(Center(Z1)+X1,0,Z1);V.UV:=Vector2(U1,Z1/6);
  if Owner=0 then V.UV:=Vector2(V.Position.X,V.Position.Z)/GROUND_MATERIALS[Mat].UVScale;
  Comp.AppendVertex(V,Mat);
  Comp.AppendTriangle(N,N+2,N+1);Comp.AppendTriangle(N+1,N+2,N+3);
end;
procedure MakeScene(Surface, Ground:Integer);
var J:Integer; Z0,Z1:Single;
begin
  Comp:=TGroundCompositeMesh.Create; Model:=TTileModel.Create;
  for J:=0 to 31 do begin
    Z0:=-16+J*3;Z1:=Z0+3;
    Strip(-RoadWidth/2,RoadWidth/2,Z0,Z1,GROUND_MAT_ROAD_DIRT,770001,0,1);
    Strip(-40,-RoadWidth/2,Z0,Z1,Ground,0,0,1);
    Strip(RoadWidth/2,40,Z0,Z1,Ground,0,0,1);
    Seg:=Default(TTileRoadSeg);Seg.WayId:=770001;Seg.X0:=Center(Z0);Seg.Z0:=Z0;
    Seg.X1:=Center(Z1);Seg.Z1:=Z1;Seg.Width:=RoadWidth;
    Seg.Surface.UVMax:=1;Seg.Surface.UVScale:=6;Seg.Surface.Asphalt:=Surface;
    Seg.Surface.ForwardLanes:=1;Seg.Surface.Condition:=3;Model.AddRoadSeg(Seg);
  end;
  Comp.TrimArrays;
  Shape:=TGroundCompositeShape.CreateShape(Comp,Atlas,Vector3(-0.5,0.7,-0.4),nil,
    '','',GROUND_COMPOSITE_VS,GROUND_COMPOSITE_FS);
  AttachRoadSurface(TIndexedFaceSetNode(Shape.Geometry),Comp,Model,Vector3(0,0,0),1);
  Root:=TX3DRootNode.Create;Root.AddChildren(Shape);AddSceneLights(Root,Vector3(-0.5,0.7,-0.4));
  Scene:=TCastleScene.Create(Window);Scene.Load(Root,True);Viewport.Items.Add(Scene);
end;
begin
  if ParamCount<3 then raise Exception.Create('OUTPUT_DIR DATA_DIR PREFIX [SURFACE=4] [GROUND=2]');
  OutDir:=IncludeTrailingPathDelimiter(ExpandFileName(ParamStr(1)));ForceDirectories(OutDir);
  ApplicationDataOverride:=ExpandFileName(ParamStr(2));Prefix:=ParamStr(3);
  Kind:=StrToIntDef(ParamStr(4),4);BackMat:=StrToIntDef(ParamStr(5),2);
  ApplicationProperties.ApplicationName:='REZVIVOUnpavedRoadProbe';
  LogFileName:=OutDir+Prefix+'.log';InitializeLog;
  Window:=TCastleWindow.Create(nil);Atlas:=TGroundAtlas.Create(DefaultGroundAtlasLayout);
  try
    Window.Visible:=False;Window.Width:=1280;Window.Height:=800;
    Viewport:=TCastleViewport.Create(Window);Viewport.FullSize:=True;
    Viewport.BackgroundColor:=Vector4(0.63,0.72,0.79,1);Window.Controls.InsertFront(Viewport);
    Camera:=TCastleCamera.Create(Window);Viewport.Items.Add(Camera);Viewport.Camera:=Camera;
    Window.Open;
    if not Atlas.TryLoadFromCache(OutDir+'atlas') then begin
      Atlas.BuildImage;if not Atlas.SaveToCache(OutDir+'atlas') then raise Exception.Create('Atlas write');
    end;
    SetRoadMaterialMode(rmmCached,False);
    if ParamStr(6)='direct' then SetRoadMaterialMode(rmmDirect,False);
    if ParamStr(6)='legacy' then SetRoadMaterialMode(rmmLegacy,False);
    MakeScene(Kind,BackMat);glGenQueries(1,@Query);
    { Explicit test-only old atlas path; the public legacy preference is an
      alias for direct procedural rendering because old asphalt is not shipped. }
    if ParamStr(6)='legacy' then
      TSFFloat(TAppearanceNode(Shape.Appearance).FdEffects[0].Field('rp_mode',False)).Send(0);
    for Quality:=0 to 1 do begin
      if Quality=0 then SetRenderProfile(orpUniversal) else SetRenderProfile(orpFull);
      SetRenderComplexity(rdWorld,Quality*3);
      for View:=0 to 1 do begin
        if View=0 then Camera.SetView(Vector3(1,2.3,-7),Vector3(-0.03,-0.11,1),Vector3(0,1,0))
        else Camera.SetView(Vector3(13,16,-5),Vector3(-11,-16,22),Vector3(0,1,0));
        for I:=0 to 99 do begin
          RoadMaterialRender(Camera.Translation);Image:=Window.SaveScreen;Image.Free;Sleep(4);
        end;
        Start:=Timer;TotalNanos:=0;
        for I:=0 to 31 do begin
          glBeginQuery(GL_TIME_ELAPSED,Query);Image:=Window.SaveScreen;Image.Free;
          glEndQuery(GL_TIME_ELAPSED);glGetQueryObjectui64v(Query,GL_QUERY_RESULT,@Nanos);Inc(TotalNanos,Nanos);
        end;
        Elapsed:=TimerSeconds(Timer,Start)*1000/32;
        Image:=Window.SaveScreen;
        SaveImage(Image,OutDir+Format('%s-q%d-view%d.png',[Prefix,Quality*3,View]));Image.Free;
        Writeln(Prefix,' quality=',Quality*3,' view=',View,' readback_frame_ms=',Elapsed:0:3,
          ' gpu_frame_ms=',TotalNanos/32000000:0:4,' ',RoadMaterialDebug);
        if glGetError()<>GL_NO_ERROR then raise Exception.Create('GL error');
      end;
    end;
  finally Window.Free;Atlas.Free;Comp.Free;Model.Free end;
end.
