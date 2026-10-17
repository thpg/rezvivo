program PuddleCameraTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,CastleVectors,CastleViewport,CastleCameras,CastleTransform,
  X3DNodes,Osm3dRoadPuddles,GameCinematicCamera;
type TGround=class
  Ready:Boolean;
  function Query(X,Z,ReferenceY:Single;out Y:Single):Boolean;
end;
function TGround.Query(X,Z,ReferenceY:Single;out Y:Single):Boolean;
begin Y:=0;Result:=Ready end;
procedure Check(V:Boolean;const M:string);
begin if not V then raise Exception.Create(M)end;
procedure Near(A,B:Single;const M:string);
begin Check(Abs(A-B)<0.0002,M)end;
var Collector:TRoadPuddleCollector;Owner:TGroupNode;Sites:TRoadPuddleSites;
  Ellipses:TPuddleEllipses;N,I,Fps,Phase:Integer;Ground:TGround;
  V:TCastleViewport;Target:TCastleTransform;Camera:TCinematicCamera;
  A,B,C,D,Up,P,Dir,OldP,ExpectedP,ExpectedD:TVector3;CA,CB,CC,CD,Style:TVector4;
  Saved:TCameraReplayState;Selected:TRoadPuddleSite;T0:QWord;Serial:Cardinal;
procedure SettleShot(Fps:Integer);
var Frame:Integer;
begin
  { Advance the director's hold time without entering a puddle shot yet. }
  Camera.PuddleReflections:=False;
  for Frame:=1 to Fps*4+1 do Camera.Update(1/Fps);
  Camera.PuddleReflections:=True;
end;
procedure Reset;
begin
  Camera.Enabled:=False;Ground.Ready:=True;
  Target.Direction:=Vector3(0,0,1);Target.Translation:=Vector3(-3,0,466);
  Camera.Setup(V,Target,nil);Camera.GroundQuery:=@Ground.Query;
  Camera.AutoSwitch:=False;Camera.PuddleReflections:=False;Camera.TargetSpeed:=7;
  Camera.Enabled:=True;Camera.Update(0);Camera.AutoSwitch:=True;
end;
begin
  N:=RoadPuddleLayout(7,0,51382,14.5,False,Ellipses);
  Check(N>=3,'road group has several puddles');
  Near(Ellipses[0].Center.X,484.55132,'GPU-compatible longitudinal position');
  Near(Ellipses[0].Center.Y,-6.87,'GPU-compatible curb offset');
  Near(Ellipses[0].Radii.X,3.9706745,'GPU-compatible long radius');
  Near(Ellipses[0].Radii.Y,0.41215054,'GPU-compatible width');
  Up:=Vector3(0,1,0);Style:=Vector4(2,2,1,51382);
  A:=Vector3(-7.25,0,448);B:=Vector3(7.25,0,448);C:=Vector3(7.25,0,512);D:=Vector3(-7.25,0,512);
  CA:=Vector4(448,-7.25,14.5,3);CB:=Vector4(448,7.25,14.5,3);
  CC:=Vector4(512,7.25,14.5,3);CD:=Vector4(512,-7.25,14.5,3);
  Collector:=TRoadPuddleCollector.Create;Owner:=TGroupNode.Create;
  V:=TCastleViewport.Create(nil);Target:=TCastleTransform.Create(nil);Ground:=TGround.Create;Camera:=TCinematicCamera.Create;
  try
    for I:=1 to 2 do begin
      Collector.Triangle(A,B,C,Up,Up,Up,CA,CB,CC,Style);
      Collector.Triangle(A,C,D,Up,Up,Up,CA,CC,CD,Style);
    end;
    Sites:=Collector.Sites;Check(Length(Sites)=N,'triangles deduplicate shared puddles');
    RegisterRoadPuddles(Owner,Sites);Check(RoadPuddleSiteCount=N,'published sparse landmarks');
    Check(FindRoadPuddle(Vector3(-3,0,466),Vector3(0,0,1),4,24,7.5,0,Selected),'nearby wet road is found');
    Check(FindRoadPuddle(Vector3(-3,0,452.5),Vector3(0,0,1),4,30,7.5,0,Selected),'near edge enters search before centre');
    Check(Selected.Radii.X>3,'large puddle is preferred over the first tiny satellite');
    Check(not FindRoadPuddle(Vector3(-3,5,466),Vector3(0,0,1),4,24,7.5,0,Selected),'do not switch to water on another deck');
    if V.Camera=nil then begin V.Camera:=TCastleCamera.Create(V);V.Items.Add(V.Camera)end;
    for Phase:=0 to 2 do begin
      case Phase of 0:Fps:=30;1:Fps:=60;else Fps:=120 end;
      Reset;Camera.Update(1/Fps);Check(Camera.Mode<>cmPuddle,'reflection disabled means no water shot');
      Camera.PuddleReflections:=True;
      for I:=1 to Fps*3 do Camera.Update(1/Fps);
      Check(Camera.Mode=cmMoto,'puddle cut interrupted a newly selected composition');
      Reset;SettleShot(Fps);Serial:=Camera.ShotSerial;Camera.Update(1/Fps);
      Check(Camera.Mode=cmPuddle,'nearby water activates prepared shot');
      Check(Camera.ShotSerial=Serial+1,'puddle entry must mark one cut');
      V.Camera.GetView(P,Dir,Up);Near(P.Y,0.55,'first cut frame already has reflective height');
      for I:=1 to Fps div 3 do begin
        Target.Translation:=Target.Translation+Vector3(0,0,7/Fps);Camera.Update(1/Fps);
      end;
      Saved:=Camera.CaptureReplay;Camera.Update(1/Fps);V.Camera.GetView(ExpectedP,ExpectedD,Up);
      Camera.RestoreReplay(Saved);Camera.Update(1/Fps);V.Camera.GetView(P,Dir,Up);
      Check((P-ExpectedP).Length<0.00001,'rewind restores the moving reflection shot');
      Check((Dir-ExpectedD).Length<0.00001,'rewind restores reflection direction');
      for I:=1 to Fps*2 do begin
        V.Camera.GetView(OldP,Dir,Up);
        Target.Translation:=Target.Translation+Vector3(0,0,7/Fps);Camera.Update(1/Fps);
        V.Camera.GetView(P,Dir,Up);
        Near(P.Z-OldP.Z,7/Fps,'reflection camera must follow continuously without transition acceleration');
      end;
      V.Camera.GetView(P,Dir,Up);
      Near(P.Y,0.55,'low reflective viewing height');
      Check((Dir.Y< -0.08)and(Dir.Y> -0.30),'grazing reflection angle');
      Check(P.X> -6.87,'lens is on the road side of the puddle');
      Saved:=Camera.CaptureReplay;Camera.Update(1/Fps);V.Camera.GetView(ExpectedP,ExpectedD,Up);
      Camera.RestoreReplay(Saved);Camera.Update(1/Fps);V.Camera.GetView(P,Dir,Up);
      Check((P-ExpectedP).Length<0.00001,'replay restores reflection camera position');
      Check((Dir-ExpectedD).Length<0.00001,'replay restores reflection camera direction');
      Serial:=Camera.ShotSerial;Camera.PuddleReflections:=False;Camera.Update(1/Fps);
      Check(Camera.Mode=cmMoto,'reflection off exits the shot');
      Check(Camera.ShotSerial=Serial+1,'puddle-to-avatar return must record a cut');
      V.Camera.GetView(P,Dir,Up);
      Check(P.Y>1,'return to rider retained the low puddle camera');
      Check(Abs(P.X-Target.Translation.X)<0.01,'return to rider is still between subjects');
      Camera.PuddleReflections:=True;
      for I:=1 to Fps*8 do Camera.Update(1/Fps);
      Check(Camera.Mode<>cmPuddle,'cooldown prevents repeated cuts for the same group');
      WriteLn('PASS reflection shot and replay at ',Fps,' fps');
    end;
    Reset;Camera.AutoSwitch:=False;Camera.PuddleReflections:=True;
    for I:=1 to 120 do Camera.Update(1/60);
    Check(Camera.Mode=cmMoto,'manual camera mode remains locked');
    Reset;SettleShot(60);Ground.Ready:=False;
    for I:=1 to 30 do Camera.Update(1/60);
    Check(Camera.Mode<>cmPuddle,'pending terrain never displays a guessed water shot');
    Ground.Ready:=True;Camera.Update(1/60);Check(Camera.Mode=cmPuddle,'ready terrain activates pending water shot');
    T0:=GetTickCount64;
    for I:=1 to 100000 do FindRoadPuddle(Vector3(-3,0,466),Vector3(0,0,1),4,24,7.5,0,Selected);
    WriteLn('100000 sparse queries: ',GetTickCount64-T0,' ms');
    FreeAndNil(Owner);Check(RoadPuddleSiteCount=0,'tile unload removes camera landmarks');
    FreeAndNil(Collector);Collector:=TRoadPuddleCollector.Create;Owner:=TGroupNode.Create;
    Up:=Vector3(0,1,0);
    { Dream roads share area UVs: world Z/X, including negative coordinates. }
    for Phase:=-1 to 1 do begin
      N:=RoadPuddleLayout(4*Phase,4,0,16,True,Ellipses);
      A:=Vector3(128,0,128*Phase);B:=A+Vector3(32,0,0);C:=B+Vector3(0,0,32);D:=A+Vector3(0,0,32);
      CA:=Vector4(A.Z,A.X,16,-1);CB:=Vector4(B.Z,B.X,16,-1);
      CC:=Vector4(C.Z,C.X,16,-1);CD:=Vector4(D.Z,D.X,16,-1);
      Collector.Triangle(A,B,C,Up,Up,Up,CA,CB,CC,TVector4.Zero);
      Collector.Triangle(A,C,D,Up,Up,Up,CA,CC,CD,TVector4.Zero);
    end;
    Sites:=Collector.Sites;Check(Length(Sites)>0,'baked area roads publish puddles');
    for I:=0 to High(Sites)do begin
      Check(Sites[I].Position.X>=128,'area axis maps to world X');
      Check(Sites[I].Position.X<=160,'area stays in its road geometry');
      Check(Sites[I].Outward.LengthSqr=0,'area does not invent a curb direction');
    end;
    RegisterRoadPuddles(Owner,Sites);Owner.Free;Owner:=nil;
    Check(RoadPuddleSiteCount=0,'Dream tile unload releases its landmarks');
    WriteLn('PUDDLE_CAMERA_OK');
  finally Camera.Free;Ground.Free;Target.Free;V.Free;Owner.Free;Collector.Free end;
end.
