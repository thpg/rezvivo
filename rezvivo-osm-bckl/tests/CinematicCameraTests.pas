program CinematicCameraTests;
{$mode objfpc}{$H+}
uses SysUtils, Math, CastleVectors, CastleTransform, CastleViewport,
  CastleCameras, GamePath, GameCinematicCamera;

type
  TGround = class
    Ready, Missing: Boolean;
    Slope, Offset: Single;
    Calls: Integer;
    function Query(X, Z, ReferenceY: Single; out Y: Single): Boolean;
  end;

function TGround.Query(X, Z, ReferenceY: Single; out Y: Single): Boolean;
begin
  Inc(Calls);
  Y := Offset + Z * Slope;
  if Z > 20 then Y := Y + 8;
  Result := not Missing and (Ready or (Z <= 20));
end;

procedure Check(const Value: Boolean; const Msg: string);
begin if not Value then raise Exception.Create(Msg) end;

procedure Near(const A, B, Epsilon: Single; const Msg: string);
begin
  Check(Abs(A - B) <= Epsilon, Format('%s: %.6f vs %.6f', [Msg, A, B]));
end;

var
  View: TCastleViewport;
  Target: TCastleTransform;
  Camera: TCinematicCamera;
  Ground: TGround;
  P, D, U, Prev, BaseDir: TVector3;
  I, J, Cuts, RearFrames: Integer;
  Seen: array[TCameraMode] of Boolean;
  PreviousMode: TCameraMode;

procedure Reset;
begin
  Camera.Enabled := False;
  Target.Translation := Vector3(0, 0, 0);
  Target.Direction := Vector3(0, 0, 1);
  Ground.Ready := True; Ground.Missing := False;
  Ground.Slope := 0; Ground.Offset := 0;
  Camera.Setup(View, Target, nil);
  Camera.GroundQuery := @Ground.Query;
  Camera.AutoSwitch := False;
  Camera.Enabled := True;
  Camera.TargetSpeed := 1;
  Camera.ClearNearby;
  Camera.Update(1/60);
end;

begin
  View := TCastleViewport.Create(nil);
  Target := TCastleTransform.Create(nil);
  Ground := TGround.Create;
  Camera := TCinematicCamera.Create;
  try
    if View.Camera = nil then
    begin
      View.Camera := TCastleCamera.Create(View);
      View.Items.Add(View.Camera);
    end;
    Reset;
    Ground.Ready := False;
    Camera.ForceMode(cmRoadside);
    Check(Camera.Mode = cmMoto, 'Pending roadside must not replace the active camera');
    Check(Camera.PendingMode = Ord(cmRoadside), 'Roadside must be pending');
    for I := 1 to 8 do Camera.Update(1/60);
    Check(Camera.Mode = cmMoto, 'Delayed GPU query must keep the previous shot');
    Ground.Ready := True;
    Camera.Update(1/60);
    Check(Camera.Mode = cmRoadside, 'Ready terrain must activate the new shot');
    View.Camera.GetView(P, D, U);
    Near(P.Y, 9.4, 0.01, 'First roadside frame already uses its own ground');
    Prev := P;
    Target.Translation := Vector3(0, 0.1, 0.4);
    Camera.Update(1/60);
    View.Camera.GetView(P, D, U);
    Near((P-Prev).Length, 0, 0.001, 'No second-frame height pop');
    Writeln('PASS async terrain: no speculative shot and no delayed 8 m pop');

    Reset;
    Ground.Ready := False;
    Camera.ForceMode(cmRoadside);
    for I := 1 to 150 do Camera.Update(1/60);
    Check(Camera.Mode = cmMoto, 'Unavailable terrain must not activate the shot');
    Check(Camera.PendingMode = -1, 'Unavailable shot must time out without blocking');
    Writeln('PASS missing terrain: bounded preparation, valid shot retained');

    Reset;
    Ground.Slope := 0.5;
    Camera.ForceMode(cmLowTrack);
    Camera.Update(1/60);
    View.Camera.GetView(Prev, D, U);
    for I := 1 to 20 do
    begin
      Target.Translation := Vector3(0, I*0.005, I*0.01);
      Camera.Update(1/60);
      View.Camera.GetView(P, D, U);
      Near(P.Y - Prev.Y, 0.005, 0.001, 'Continuous floor between 30 cm boundaries');
      Prev := P;
    end;
    Camera.TargetSpeed := 0;
    for I := 1 to 200 do Camera.Update(1/60);
    Check(Camera.Mode = cmLowTrack, 'AutoSwitch=false must also disable stop/start cuts');
    Writeln('PASS slope sampling and manual mode lock');

    Reset;
    Camera.ForceMode(cmLowTrack);
    Camera.Update(1/60);
    View.Camera.GetView(Prev, D, U);
    Ground.Offset := -2;
    Camera.Update(1/60);
    View.Camera.GetView(P, D, U);
    Check((Prev.Y-P.Y > 0) and (Prev.Y-P.Y < 0.3), 'A late lower floor must ease down');
    Ground.Offset := 1;
    Camera.Update(1/60);
    View.Camera.GetView(P, D, U);
    Check(P.Y >= 1.5, 'Height smoothing must not cross an uphill surface');
    Writeln('PASS terrain-height damping with hard ground clearance');

    Reset;
    Camera.ForceMode(cmRoadside);
    Camera.Update(1/60);
    Camera.Enabled := False;
    Target.Translation := Vector3(100, 0, 100);
    Camera.Enabled := True;
    Camera.Update(1/60);
    Check(Camera.Mode = cmMoto, 'Reactivating must not reuse a stale fixed anchor');
    View.Camera.GetView(P, D, U);
    Check((P-Target.Translation).Length < 20, 'Reactivated camera follows current rider');
    Camera.ForceMode(cmStandShot);
    Camera.Update(1/60);
    Ground.Offset := 181;
    Target.Translation := Vector3(100, 181, 100);
    Camera.Update(1/60);
    Check(Camera.Mode = cmMoto, 'World-height initialization invalidates old anchors');
    View.Camera.GetView(P, D, U);
    Check(P.Y > 181, 'Camera follows the initialized ground level');
    Writeln('PASS resume and world-height relocation');

    Reset;
    Camera.Update(1/60);
    View.Camera.GetView(P, BaseDir, U);
    Camera.AddNearby(Vector3(17.9994, 0, 23.9992));
    Camera.Update(1/60);
    View.Camera.GetView(P, D, U);
    Check((D-BaseDir).Length < 0.001, 'A bot at the collection boundary must fade in');
    Camera.ClearNearby;
    Camera.Update(1/60);
    View.Camera.GetView(P, D, U);
    Check((D-BaseDir).Length < 0.001, 'A disappearing bot must preserve the original aim');
    Writeln('PASS continuous framing at the nearby-rider boundary');

    Reset;
    Camera.AutoSwitch := True;
    Camera.TargetSpeed := 0;
    for I := 1 to 80 do Camera.Update(1/60);
    Check(Camera.Mode = cmMoto, 'A brief stop must not cut immediately');
    for I := 1 to 20 do Camera.Update(1/60);
    Check(Camera.Mode = cmStandShot, 'A sustained stop uses a prepared stationary shot');
    Camera.TargetSpeed := 0.5;
    for I := 1 to 10 do Camera.Update(1/60);
    Check(Camera.Mode = cmStandShot, 'Stop/start hysteresis must not chatter');
    Camera.TargetSpeed := 1;
    Camera.Update(1/60);
    Check(Camera.Mode = cmMoto, 'Moving resumes the follow shot');
    Writeln('PASS stationary-shot entry and exit hysteresis');

    Reset;
    RandSeed := 48291;
    Camera.AutoSwitch := True;
    Camera.TargetSpeed := 7;
    FillChar(Seen, SizeOf(Seen), 0);
    Cuts := 0; RearFrames := 0; PreviousMode := Camera.Mode;
    { Ten minutes of a real timed camera sequence, including terrain readiness.
      The rear view must remain available without alternating every other cut. }
    for I := 1 to 36000 do
    begin
      Target.Translation := Vector3(0, 8, 100+I*7/60);
      Camera.Update(1/60);
      Seen[Camera.Mode] := True;
      if Camera.Mode=cmMoto then Inc(RearFrames);
      if Camera.Mode<>PreviousMode then Inc(Cuts);
      PreviousMode := Camera.Mode;
    end;
    J := 0;
    for PreviousMode := cmMoto to cmLowTrack do if Seen[PreviousMode] then Inc(J);
    Check(J=5, 'All five moving shots must be used');
    Check(Seen[cmFrontQuarterLeft] and Seen[cmFrontQuarterRight],
      'Both front three-quarter shots must enter the automatic sequence');
    Check(Cuts>55, 'Moving sequence should not stay in a single shot');
    Check((RearFrames>3600) and (RearFrames<16200), 'Rear view should occupy 10-45% of the timed sequence');
    Writeln('PASS moving-shot variety: cuts=', Cuts, ' rear=', RearFrames/360:0:1, '%');
  finally
    Camera.Free; Ground.Free; Target.Free; View.Free;
  end;
end.
