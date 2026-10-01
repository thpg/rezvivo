unit RiderPoseCatalog;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses RiderTripo;

const BuiltinRiderPoseCount = 17;

function BuiltinRiderPose(Index: Integer): TRiderPose;
procedure LoadBuiltinRiderPoses(List: TRiderPoseList);

implementation

uses SysUtils, Math, CastleVectors, RiderHandGrip;

function BuiltinRiderPose(Index: Integer): TRiderPose;
var CurveTransfer: Single;
begin
  Result := DefaultRiderPose;
  Result.SpineManual := True;
  Result.Motion.Pedalling := 1;
  Result.Motion.Breathing := 1;
  Result.Motion.AnkleDeg := 7;
  Result.PedalSway := 0.004;
  Result.TorsoBobAmp := 0.0015;
  case Index of
    0: begin { Seated hoods / endurance }
      Result.Name := 'Default';
      Result.OffsetX := -0.1;
      Result.ShoulderRoundDeg := 12;
      Result.SpineAngles[0] := -54;
      Result.SpineAngles[1] := -3;
      Result.SpineAngles[2] := -2;
      Result.SpineAngles[3] := -1;
      Result.SpineAngles[4] := 12;
    end;
    1: begin { Standing sprint / drops }
      Result.Name := 'Pose 1';
      Result.OffsetX := 0.06;
      Result.OffsetY := 0.025;
      Result.AnkleFlex := 10;
      { Neutral grip orientation is derived from the handlebar contact. }
      Result.HandPosR := 3;
      Result.HandPosL := 3;
      Result.SelPriority := 30;
      Result.SelSpeedMin := 5;
      Result.SelIntensityMin := 1.8;
      Result.SpineAngles[0] := -70;
      Result.SpineAngles[1] := -6;
      Result.SpineAngles[2] := -5;
      Result.SpineAngles[3] := -3;
      Result.SpineAngles[4] := 18;
      Result.Motion.Standing := 1;
      Result.Motion.Sprint := 1;
      Result.PedalSway := 0.020;
      Result.TorsoBobAmp := 0.005;
      Result.Motion.AnkleDeg := 9;
    end;
    2: begin { Asymmetric reach (event) }
      Result.Name := 'Pose 2';
      Result.OffsetY := -0.03;
      Result.OffsetZ := -0.04;
      Result.HandPosL := 3;
      Result.Special := True;
      Result.SpineAngles[0] := -55;
      Result.SpineAngles[1] := -5;
      Result.SpineAngles[2] := -4;
      Result.SpineAngles[3] := -2;
      Result.SpineAngles[4] := 15;
      Result.Motion.Pedalling := 0;
    end;
    3: begin { Relaxed tops }
      Result.Name := 'Pose 3';
      Result.OffsetX := -0.1;
      Result.TorsoLeanDeg := 0;
      Result.HandLevel := 0;
      Result.HandPosR := 5;
      Result.HandPosL := 5;
      Result.SelPriority := 5;
      Result.SelSpeedMin := 2;
      Result.SelSpeedMax := 20;
      Result.SelIntensityMax := 0.85;
      Result.SpineAngles[0] := -43;
      Result.SpineAngles[1] := -3;
      Result.SpineAngles[2] := -2;
      Result.SpineAngles[3] := 0;
      Result.SpineAngles[4] := 8;
    end;
    4: begin { Seated aero on the hoods; this bar has no aero extensions }
      Result.Name := 'Pose 4';
      Result.OffsetX := -0.1;
      Result.TorsoLeanDeg := 0;
      Result.HandPosR := 1;
      Result.HandPosL := 1;
      Result.SelPriority := 12;
      Result.SelSpeedMin := 30;
      Result.SelIntensityMax := 1.5;
      Result.SpineAngles[0] := -72;
      Result.SpineAngles[1] := -5;
      Result.SpineAngles[2] := -5;
      Result.SpineAngles[3] := -3;
      Result.SpineAngles[4] := 25;
      Result.Motion.SeatedPower := 1;
      Result.PedalSway := 0.003;
      Result.TorsoBobAmp := 0.0008;
    end;
    5: begin { Stretch legs (event) }
      Result.Name := 'Pose 5';
      Result.OffsetX := -0.1;
      Result.HandPosR := 2;
      Result.HandPosL := 5;
      Result.LegFreeR := 1;
      Result.LegFreeL := 1;
      Result.Special := True;
      Result.SelPriority := 10;
      Result.SelSpeedMin := 10;
      Result.SelSpeedMax := 88;
      Result.SelGradeMax := -1;
      Result.SpineAngles[0] := -50;
      Result.SpineAngles[1] := -4;
      Result.SpineAngles[2] := -3;
      Result.SpineAngles[3] := -2;
      Result.SpineAngles[4] := 16;
      Result.LegFreeRPos := Vector3(0, 0.5, 0);
      Result.LegFreeLPos := Vector3(0.1, 0.5, 0);
      Result.Motion.Pedalling := 0;
    end;
    6: begin { Stopped, one foot down }
      Result.Name := 'Pose 6';
      Result.Grounded := True;
      Result.OffsetX := 0.2;
      Result.OffsetY := -0.1;
      Result.HandLevel := 0;
      Result.HandPosR := 1;
      Result.HandPosL := 1;
      Result.LegFreeR := 1;
      Result.SelPriority := 40;
      Result.SelSpeedMax := 1;
      Result.SelIntensityMax := 0.1;
      Result.SpineAngles[0] := -12;
      Result.SpineAngles[1] := 0;
      Result.SpineAngles[2] := 0;
      Result.SpineAngles[3] := 0;
      Result.SpineAngles[4] := 4;
      Result.LegFreeRPos := Vector3(0, 0, 0.2);
      Result.LegFreeLPos := Vector3(0.1, 0.5, 0);
      Result.Motion.Pedalling := 0;
    end;
    7: begin { Drink (event) }
      Result.Name := 'Вода';
      Result.HandPosR := 0;
      Result.HandFreeRWave := 0.02;
      Result.Special := True;
      Result.SpineAngles[0] := -46;
      Result.SpineAngles[1] := -3;
      Result.SpineAngles[2] := -2;
      Result.SpineAngles[3] := -1;
      Result.SpineAngles[4] := 10;
      Result.HandFreeRPos := Vector3(0, 1, 0.4);
    end;
    8: begin { No hands / celebration (event) }
      Result.Name := 'Pose 8';
      Result.OffsetX := -0.1;
      Result.AnkleFlex := 10;
      Result.HandLevel := 0;
      Result.HandPosR := 0;
      Result.HandPosL := 0;
      Result.HandFreeRWave := 0.01;
      Result.HandFreeLWave := 0.01;
      Result.Special := True;
      Result.SelPriority := 10;
      Result.SelSpeedMin := 15;
      Result.SelSpeedMax := 25;
      Result.SelIntensityMax := 3;
      Result.SelGradeMin := -3;
      Result.SelGradeMax := 3;
      Result.SpineAngles[0] := -20;
      Result.SpineAngles[1] := -2;
      Result.SpineAngles[2] := 0;
      Result.SpineAngles[3] := 0;
      Result.SpineAngles[4] := 5;
      Result.HandFreeRPos := Vector3(0.3, 1.2, 0.3);
      Result.HandFreeLPos := Vector3(0.3, 1.2, -0.3);
    end;
    9: begin { Seated cornering }
      Result.Name := 'Pose 9';
      Result.OffsetX := -0.1;
      Result.SelPriority := 20;
      Result.SelSpeedMin := 5;
      Result.SelIntensityMax := 4;
      Result.SelGradeMin := -7;
      Result.SelGradeMax := 7;
      Result.TurnSuitable := True;
      Result.SpineAngles[0] := -50;
      Result.SpineAngles[1] := -3;
      Result.SpineAngles[2] := -3;
      Result.SpineAngles[3] := -2;
      Result.SpineAngles[4] := 14;
    end;
    10: begin { Stopped, both feet down }
      Result.Name := 'Pose 10';
      Result.Grounded := True;
      Result.OffsetX := 0.15;
      Result.OffsetY := -0.1;
      Result.OffsetZ := 0.05;
      Result.HandPosR := 0;
      Result.HandPosL := 5;
      Result.LegFreeR := 1;
      Result.LegFreeL := 1;
      Result.SelPriority := 39; { one-foot support is the normal traffic stop }
      Result.SelSpeedMax := 1;
      Result.SelIntensityMax := 0.05;
      Result.SpineAngles[0] := -12;
      Result.SpineAngles[1] := 0;
      Result.SpineAngles[2] := 0;
      Result.SpineAngles[3] := 0;
      Result.SpineAngles[4] := 4;
      Result.HandFreeRPos := Vector3(0.4, 0.8, 0.2);
      Result.HandFreeLPos := Vector3(-0.3, 0, 0);
      Result.LegFreeRPos := Vector3(0.1, 0, 0.3);
      Result.LegFreeLPos := Vector3(0.1, 0, -0.3);
      Result.Motion.Pedalling := 0;
    end;
    11: begin { Seated climbing }
      Result.Name := 'Pose 11';
      Result.OffsetX := -0.1;
      Result.SelPriority := 15;
      Result.SelSpeedMin := 5;
      Result.SelSpeedMax := 45;
      Result.SelIntensityMax := 7;
      Result.SelGradeMin := 2;
      Result.SelGradeMax := 7;
      Result.SpineAngles[0] := -47;
      Result.SpineAngles[1] := -4;
      Result.SpineAngles[2] := -3;
      Result.SpineAngles[3] := -1;
      Result.SpineAngles[4] := 12;
    end;
    12: begin { Low hoods / descent }
      Result.Name := 'Pose 12';
      Result.OffsetX := -0.05;
      Result.TorsoLeanDeg := 0;
      Result.HandLevel := 0;
      Result.SelPriority := 1;
      Result.SelSpeedMin := 1;
      Result.SelIntensityMax := 5;
      Result.SelGradeMin := -7;
      Result.SelGradeMax := 0;
      Result.TurnSuitable := True;
      Result.SpineAngles[0] := -55;
      Result.SpineAngles[1] := -4;
      Result.SpineAngles[2] := -3;
      Result.SpineAngles[3] := -2;
      Result.SpineAngles[4] := 18;
    end;
    13: begin { Drops / descending }
      Result.Name := 'Pose 13';
      Result.OffsetX := -0.07;
      Result.HandLevel := 0;
      Result.HandPosR := 4;
      Result.HandPosL := 4;
      Result.SelPriority := 10;
      Result.SelSpeedMin := 15;
      Result.SelSpeedMax := 99;
      Result.SelIntensityMax := 0.15;
      Result.SelGradeMin := -20;
      Result.SelGradeMax := 5;
      Result.TurnSuitable := True;
      Result.SpineAngles[0] := -59;
      Result.SpineAngles[1] := -5;
      Result.SpineAngles[2] := -4;
      Result.SpineAngles[3] := -2;
      Result.SpineAngles[4] := 24;
      Result.LegFreeRPos := Vector3(-0.5, 0.4, 0);
      Result.LegFreeLPos := Vector3(-0.5, 0.4, 0);
      Result.PedalSway := 0.002;
      Result.TorsoBobAmp := 0.0008;
    end;
    14: begin { Dismount (event) }
      Result.Name := 'Pose 14';
      Result.Grounded := True;
      Result.OffsetX := -0.15;
      Result.OffsetY := -0.05;
      Result.OffsetZ := -0.4;
      Result.HandLevel := 0;
      Result.HandPosR := 0;
      Result.HandPosL := 0;
      Result.LegFreeR := 1;
      Result.LegFreeL := 1;
      Result.Special := True;
      Result.SelPriority := 1;
      Result.SelSpeedMax := 0;
      Result.SelIntensityMax := 0;
      Result.SelGradeMin := 0;
      Result.SelGradeMax := 0;
      Result.TurnSuitable := True;
      Result.SpineAngles[0] := -12;
      Result.SpineAngles[1] := 0;
      Result.SpineAngles[2] := 0;
      Result.SpineAngles[3] := 0;
      Result.SpineAngles[4] := 4;
      Result.HandFreeRPos := Vector3(-0.25, 0.8, 0.05);
      Result.HandFreeLPos := Vector3(-0.3, 0.8, -0.6);
      Result.LegFreeRPos := Vector3(0, 0, -0.1);
      Result.LegFreeLPos := Vector3(0.1, 0, -0.4);
      Result.Motion.Pedalling := 0;
    end;
    15: begin { Standing climb on the hoods }
      Result := BuiltinRiderPose(1);
      Result.Name := 'Standing climb';
      Result.Motion.Sprint := 0;
      Result.OffsetY := 0.035;
      Result.HandPosR := 1; Result.HandPosL := 1;
      Result.ArmPronationR := 0; Result.ArmPronationL := 0;
      { Pose 1 already distributes eight degrees into Spine01/Spine02. }
      Result.SpineAngles[0] := -35;
      Result.SelIntensityMin := 0.9; Result.SelIntensityMax := 1.8;
      Result.SelGradeMin := 5; Result.SelGradeMax := 99;
      Result.SelSpeedMin := 2; Result.SelSpeedMax := 40;
      Result.PedalSway := 0.018;
      Result.TorsoBobAmp := 0.004;
    end;
    16: begin { Loaded seated riding also at climbing / headwind speeds }
      Result := BuiltinRiderPose(4);
      Result.Name := 'Seated power';
      Result.SelPriority := 21;
      Result.SelSpeedMin := 2;
      Result.SelIntensityMin := 1.05;
      Result.SelIntensityMax := 1.8;
      { No absolute watt threshold: the reference's 500 W rider stays seated.
        The standing climb and sprint retain their higher priorities. }
    end;
    else raise ERangeError.CreateFmt('Unknown rider pose %d', [Index]);
  end;
  { Spread forward flexion over lumbar and thoracic regions. The total trunk
    angle stays the same, while the back no longer hinges almost entirely at
    Waist. Slot 1 is absent on MEN/FEM, so use the two actual spine joints.
    Derived climbing / power poses inherit this adjustment above. }
  if not (Index in [15,16]) then begin
    CurveTransfer:=EnsureRange((-Result.SpineAngles[0]-24)*0.267,0.0,8.0);
    Result.SpineAngles[0]:=Result.SpineAngles[0]+CurveTransfer;
    Result.SpineAngles[2]:=Result.SpineAngles[2]-CurveTransfer*0.375;
    Result.SpineAngles[3]:=Result.SpineAngles[3]-CurveTransfer*0.625;
  end;
  Result.HandFrameR:=RiderGripFrame(Result.HandPosR,0);
  Result.HandFrameL:=RiderGripFrame(Result.HandPosL,1);
end;

procedure LoadBuiltinRiderPoses(List: TRiderPoseList);
var I: Integer;
begin
  List.Clear;
  for I := 0 to BuiltinRiderPoseCount - 1 do List.Add(BuiltinRiderPose(I));
end;

end.
