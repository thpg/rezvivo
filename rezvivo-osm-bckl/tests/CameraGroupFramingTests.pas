program CameraGroupFramingTests;
{$mode objfpc}{$H+}
uses SysUtils, Math, CastleVectors, CastleTransform, CastleViewport,
  CastleCameras, GameCinematicCamera;

type TGround = class
  function Query(X,Z,ReferenceY:Single;out Y:Single):Boolean;
end;
function TGround.Query(X,Z,ReferenceY:Single;out Y:Single):Boolean;
begin Y:=0;Result:=True end;

var View:TCastleViewport;Target:TCastleTransform;Camera:TCinematicCamera;
  Ground:TGround;P,D,U,BaseP,BaseD,PrevD:TVector3;
  I,Fps:Integer;T,MaxYaw,MaxMove,MaxRate,Rate,FrontYaw:Single;
  Measure:Boolean;
  Saved:TCameraReplayState;
  ExpectedP,ExpectedD:array[1..30]of TVector3;

function Yaw(const V:TVector3):Single;
begin Result:=RadToDeg(ArcTan2(V.X,V.Z)) end;
procedure Check(V:Boolean;const Message:string);
begin if not Measure and not V then raise Exception.Create(Message) end;
procedure Reset;
begin
  Camera.Enabled:=False;
  Target.Translation:=Vector3(0,0,0);Target.Direction:=Vector3(0,0,1);
  Camera.Setup(View,Target,nil);Camera.GroundQuery:=@Ground.Query;
  Camera.AutoSwitch:=False;Camera.TargetSpeed:=7;
  Camera.Enabled:=True;Camera.ClearNearby;Camera.Update(0);
  View.Camera.GetView(BaseP,BaseD,U);
end;

begin
  Measure:=(ParamCount>0)and(ParamStr(1)='--measure');
  View:=TCastleViewport.Create(nil);Target:=TCastleTransform.Create(nil);
  Camera:=TCinematicCamera.Create;Ground:=TGround.Create;
  try
    if View.Camera=nil then begin
      View.Camera:=TCastleCamera.Create(View);View.Items.Add(View.Camera);
    end;
    for Fps in [30,60,144] do begin
      Reset;MaxYaw:=0;MaxMove:=0;
      { A drafting rider passes behind the lens. The old group centroid
        passes through the camera and reverses the aim every second. }
      for I:=1 to Fps*6 do begin
        T:=I/Fps;Target.Translation:=Vector3(0,0,T*7);
        Camera.ClearNearby;
        Camera.AddNearby(Target.Translation+Vector3(0.12*Sin(T*2*Pi),0,-4.7+0.7*Cos(T*2*Pi)));
        Camera.Update(1/Fps);View.Camera.GetView(P,D,U);
        MaxYaw:=Max(MaxYaw,Abs(Yaw(D)-Yaw(BaseD)));
        MaxMove:=Max(MaxMove,(P-Target.Translation-BaseP).Length);
      end;
      Writeln('behind fps=',Fps,' yaw_deg=',MaxYaw:0:6,' offset_m=',MaxMove:0:6);
      Check(MaxYaw<0.2,'A rider behind the lens must not turn the follow camera');
      Check(MaxMove<0.01,'A rider behind the lens must not pull the follow camera');

      Reset;PrevD:=BaseD;MaxRate:=0;
      { Appearing/disappearing company changes composition, not the camera
        mode. It must not produce a one-frame pan. }
      for I:=1 to Fps*8 do begin
        T:=I/Fps;Camera.ClearNearby;
        if (T>=1)and(T<5) then Camera.AddNearby(Vector3(3,0,6));
        Camera.Update(1/Fps);View.Camera.GetView(P,D,U);
        Rate:=Abs(Yaw(D)-Yaw(PrevD))*Fps;MaxRate:=Max(MaxRate,Rate);PrevD:=D;
        if I=Fps*4 then FrontYaw:=Abs(Yaw(D)-Yaw(BaseD));
      end;
      Writeln('entry fps=',Fps,' rate_deg_s=',MaxRate:0:6,' front_yaw=',FrontYaw:0:6);
      Check(FrontYaw>1,'Visible riders ahead must still influence framing');
      Check(MaxRate<35,'Company entry/exit must not snap the direction');
      Check(Abs(Yaw(D)-Yaw(BaseD))<0.1,'Camera must settle after company leaves');

      Reset;
      Camera.AddNearby(Vector3(3,0,6));
      for I:=1 to 10 do Camera.Update(1/Fps);
      Saved:=Camera.CaptureReplay;
      for I:=1 to 30 do begin
        Camera.ClearNearby;Camera.AddNearby(Vector3(3+I/30,0,6));
        Camera.Update(1/Fps);View.Camera.GetView(ExpectedP[I],ExpectedD[I],U);
      end;
      Camera.RestoreReplay(Saved);
      for I:=1 to 30 do begin
        Camera.ClearNearby;Camera.AddNearby(Vector3(3+I/30,0,6));
        Camera.Update(1/Fps);View.Camera.GetView(P,D,U);
        Check((P-ExpectedP[I]).Length<0.00001,'Replay lost group follow position');
        Check((D-ExpectedD[I]).Length<0.00001,'Replay lost group framing state');
      end;
      Writeln('replay fps=',Fps,' matched=30');
    end;
  finally Ground.Free;Camera.Free;Target.Free;View.Free end;
  Writeln('CAMERA_GROUP_FRAMING_OK');
end.
