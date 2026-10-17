program CameraDreamGroundTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,CastleVectors,CastleTransform,CastleViewport,CastleCameras,
  Osm3dDreamWorld,GameCinematicCamera;
procedure Check(Value:Boolean;const Message:string);
begin if not Value then raise Exception.Create(Message)end;
var World:TDreamWorld;View:TCastleViewport;Target:TCastleTransform;
  Camera:TCinematicCamera;Saved:TCameraReplayState;P,D,U,Prev,Offset:TVector3;
  Mode:TCameraMode;I:Integer;Y:Single;
begin
  { CPU only: decode the actual Dream mesh, without materials or a GL context. }
  World:=TDreamWorld.Create(ParamStr(1));View:=TCastleViewport.Create(nil);
  Target:=TCastleTransform.Create(nil);Camera:=TCinematicCamera.Create;
  try
    View.Camera:=TCastleCamera.Create(View);View.Items.Add(View.Camera);
    View.Camera.Perspective.FieldOfView:=Pi/4;
    { Captured coast-road failure: a circular rear-to-front sweep reached
      this point outside the known walkable surface and never activated. }
    Check(not World.GroundNearYAt(264.8712,23.3347,1,Y),
      'fixture no longer covers the narrow coastal edge');
    for Mode:=cmFrontQuarterLeft to cmFrontQuarterRight do begin
      Camera.Enabled:=False;
      Target.Translation:=Vector3(260.7890015,1,25.4857769);
      Target.Direction:=Vector3(0.17465222,0,0.98463017);
      Camera.Setup(View,Target,nil);Camera.GroundQuery:=@World.GroundNearYAt;
      Camera.Enabled:=True;Camera.AutoSwitch:=False;Camera.TargetSpeed:=3.1954;
      Camera.Update(0);Saved:=Camera.CaptureReplay;
      Saved.CamPos:=Vector3(259.9936829,2.4344425,21.0020084);
      Saved.CamDir:=Vector3(0.05351087,-0.15413915,0.98659903);
      Camera.RestoreReplay(Saved);Prev:=Saved.CamPos;
      Camera.ForceMode(Mode);
      Check((Camera.Mode=Mode)and(Camera.PendingMode=-1),
        'valid coast-road close shot rejected because the space between shots is unwalkable');
      Camera.Update(0);View.Camera.GetView(Prev,D,U);
      Check(TVector3.DotProduct(Prev-Target.Translation,Target.Direction)>2.8,
        'coastal close-up must reach its destination on the cut frame');
      for I:=1 to 90 do begin
        Target.Translation:=Target.Translation+Target.Direction*(3.1954/60);
        Camera.Update(1/60);View.Camera.GetView(P,D,U);
        Check(World.GroundNearYAt(P.X,P.Z,1,Y),'tracking left verified ground');
        Check(P.Y>=Y+0.49,'tracking crossed the terrain');
        Offset:=P-Target.Translation;Offset.Y:=0;
        Check(Offset.Length>=2.799,'tracking crossed the rider clearance');
        Check((P-Prev).Length<0.4,'coastal tracking jumped after the cut');Prev:=P;
      end;
      Check(Camera.Mode=Mode,'safe close shot ended unexpectedly');
      Check(TVector3.DotProduct(P-Target.Translation,Target.Direction)>2.8,
        'camera did not arrive ahead of the moving rider');
    end;
    Writeln('PASS actual Dream coast geometry: direct cuts, moving shots, rider clearance, no missing-ground bypass');
  finally Camera.Free;Target.Free;View.Free;World.Free end;
end.
