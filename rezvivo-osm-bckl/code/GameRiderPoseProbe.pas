unit GameRiderPoseProbe;
{$mode objfpc}{$H+}
interface
uses CastleScene, fpjson;
{ Explicit MCP diagnostic only. No readback or work in the normal frame. }
function DumpRiderPose(const Scene: TCastleScene; const Path: string): TJSONObject;
implementation
uses Classes, SysUtils, CastleShapes, CastleInternalRenderer, CastleTransform,
  CastleVectors, CastleGL;

function DumpRiderPose(const Scene: TCastleScene; const Path: string): TJSONObject;
{$ifndef OpenGLES}
var Shapes: TShapeList; Shape: TX3DRendererShape; I: Integer;
  Coordinates, Indices, Stride, Count, IndexCount: Cardinal;
  Posed: Boolean; OldBuffer: GLint; Data: array of Single;
  Stream: TFileStream; Items: TJSONArray; Item: TJSONObject;
  Params: TRenderParams; Transform: TTransformation;
{$endif}
begin
  {$ifdef OpenGLES}
  raise Exception.Create('Pose readback diagnostic requires desktop OpenGL');
  Result := nil;
  {$else}
  if (Scene=nil) or (Scene.Shapes=nil) then raise Exception.Create('No rider geometry');
  if not Assigned(glGetBufferSubData) then raise Exception.Create('No buffer readback');
  Items:=TJSONArray.Create;
  Result:=TJSONObject.Create;
  Result.Add('shapes',Items);
  Result.Add('layout','float32 position[3], normal[3], tangent[4]; local mesh space');
  Params:=TRenderParams.Create;
  Params.RenderingCamera:=TRenderingCamera.Create;
  { Use the detail selected by the preceding draw, without asking the LOD
    filter to evaluate an artificial screen projection. }
  Params.RenderingCamera.Target:=rtShadowMap;
  Params.RenderingCamera.Matrix:=TMatrix4.Identity;
  Params.RenderingCamera.Projection:=TMatrix4.Identity;
  Transform:=IdentityTransformation;
  Transform.Transform:=Scene.WorldTransform;
  Transform.InverseTransform:=Scene.WorldInverseTransform;
  Params.Transformation:=@Transform;
  Stream:=nil;
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer);
  try
   try
    Stream:=TFileStream.Create(Path,fmCreate);
    Shapes:=Scene.Shapes.TraverseList(True,True,False);
    for I:=0 to Shapes.Count-1 do
    begin
      if not(Shapes[I] is TX3DRendererShape) then Continue;
      Shape:=TX3DRendererShape(Shapes[I]);
      if not Shape.State.SkinnedAnimatedShape then Continue;
      if (Shape.Node<>nil) and not Shape.Node.Visible then Continue;
      if Assigned(Scene.OnRenderShapeFilter) and
         not Scene.OnRenderShapeFilter(Shape.Node,Params) then Continue;
      if not Shape.DeformedQueryBuffers(Coordinates,Indices,Stride,Count,IndexCount,Posed)
         or not Posed or (Count=0) then Continue;
      if Stride<>10*SizeOf(Single) then raise Exception.Create('Unexpected posed vertex stride');
      SetLength(Data,Count*10);
      glBindBuffer(GL_ARRAY_BUFFER,Coordinates);
      glGetBufferSubData(GL_ARRAY_BUFFER,0,Count*Stride,@Data[0]);
      Item:=TJSONObject.Create;
      Item.Add('name',Shape.Node.X3DName);
      Item.Add('offset',Stream.Position);
      Item.Add('vertices',Int64(Count));
      Items.Add(Item);
      Stream.WriteBuffer(Data[0],Count*Stride);
    end;
    Result.Add('bytes',Stream.Size);
    if Items.Count=0 then raise Exception.Create('No posed GPU buffers; enable pose cache and render first');
  except
    FreeAndNil(Result);
    raise;
   end;
  finally
    glBindBuffer(GL_ARRAY_BUFFER,OldBuffer);
    Stream.Free;
    Params.RenderingCamera.Free;
    Params.Free;
  end;
  {$endif}
end;
end.
