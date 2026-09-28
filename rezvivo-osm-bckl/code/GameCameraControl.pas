{ TCameraController — wraps ThirdPersonNavigation configuration,
  checkbox handlers, and transformation mode switching.
  Extracted from TViewPlay to reduce god-object complexity. }
unit GameCameraControl;

interface

uses
  Classes, CastleVectors,
  CastleUIControls, CastleControls, CastleKeysMouse, CastleThirdPersonNavigation,
  CastleDebugTransform, CastleTransform, CastleInputs,
  GamePhysicalAgent;

type
  {$M+}
  TCameraController = class
  private
    FNavigation: TCastleThirdPersonNavigation;
    FDebugAvatar: TDebugTransform;

    { Checkboxes }
    FCheckCameraFollows: TCastleCheckbox;
    FCheckAimAvatar: TCastleCheckbox;
    FCheckDebugColliders: TCastleCheckbox;
    FCheckImmediatelyFix: TCastleCheckbox;

    { Sliders }
    FSliderAirRotation: TCastleFloatSlider;
    FSliderAirMovement: TCastleFloatSlider;

    { Transformation buttons }
    FBtnAuto, FBtnDirect, FBtnVelocity, FBtnForce: TCastleButton;

    procedure DoChangeCameraFollows(Sender: TObject);
    procedure DoChangeAimAvatar(Sender: TObject);
    procedure DoChangeDebugColliders(Sender: TObject);
    procedure DoChangeImmediatelyFix(Sender: TObject);
    procedure DoChangeAirRotation(Sender: TObject);
    procedure DoChangeAirMovement(Sender: TObject);
    procedure DoClickAuto(Sender: TObject);
    procedure DoClickDirect(Sender: TObject);
    procedure DoClickVelocity(Sender: TObject);
    procedure DoClickForce(Sender: TObject);

    procedure UpdateTransformationButtons;
  public
    constructor Create;

    { Bind all UI controls and navigation — call once after design load.
      AvatarTransform is used to parent the debug transform. }
    procedure Setup(
      ANavigation: TCastleThirdPersonNavigation;
      AAvatarTransform: TCastleTransform;
      AOwner: TComponent;
      ACheckCameraFollows, ACheckAimAvatar,
        ACheckDebugColliders, ACheckImmediatelyFix: TCastleCheckbox;
      ASliderAirRotation, ASliderAirMovement: TCastleFloatSlider;
      ABtnAuto, ABtnDirect, ABtnVelocity, ABtnForce: TCastleButton
    );

    { Apply initial navigation settings — call after Setup }
    procedure InitDefaults;

    { Orbit from a drag delta without enabling pointer lock. }
    procedure DragRotate(const Delta: TVector2; AActiveAgent: TPhysicalAgent);

    property DebugAvatar: TDebugTransform read FDebugAvatar;
  published
    { Навигация третьего лица — объектное свойство, через RTTI доступны
      все published-настройки TCastleThirdPersonNavigation
      (camera.follows, distance и т.д. dotted-путями). }
    property Navigation: TCastleThirdPersonNavigation read FNavigation;
  end;
  {$M-}

implementation

type
  { Reuse the CGE orbit calculation without its pointer-lock input. }
  TDragNavigationAccess = class(TCastleThirdPersonNavigation);

constructor TCameraController.Create;
begin
  inherited;
end;

procedure TCameraController.Setup(
  ANavigation: TCastleThirdPersonNavigation;
  AAvatarTransform: TCastleTransform;
  AOwner: TComponent;
  ACheckCameraFollows, ACheckAimAvatar,
    ACheckDebugColliders, ACheckImmediatelyFix: TCastleCheckbox;
  ASliderAirRotation, ASliderAirMovement: TCastleFloatSlider;
  ABtnAuto, ABtnDirect, ABtnVelocity, ABtnForce: TCastleButton);
begin
  FNavigation := ANavigation;

  FCheckCameraFollows := ACheckCameraFollows;
  FCheckAimAvatar := ACheckAimAvatar;
  FCheckDebugColliders := ACheckDebugColliders;
  FCheckImmediatelyFix := ACheckImmediatelyFix;
  FSliderAirRotation := ASliderAirRotation;
  FSliderAirMovement := ASliderAirMovement;
  FBtnAuto := ABtnAuto;
  FBtnDirect := ABtnDirect;
  FBtnVelocity := ABtnVelocity;
  FBtnForce := ABtnForce;

  { Create debug transform }
  FDebugAvatar := TDebugTransform.Create(AOwner);
  FDebugAvatar.Parent := AAvatarTransform;

  { Bind event handlers }
  if Assigned(FCheckCameraFollows) then
    FCheckCameraFollows.OnChange := {$ifdef FPC}@{$endif} DoChangeCameraFollows;
  if Assigned(FCheckAimAvatar) then
    FCheckAimAvatar.OnChange := {$ifdef FPC}@{$endif} DoChangeAimAvatar;
  if Assigned(FCheckDebugColliders) then
    FCheckDebugColliders.OnChange := {$ifdef FPC}@{$endif} DoChangeDebugColliders;
  if Assigned(FCheckImmediatelyFix) then
    FCheckImmediatelyFix.OnChange := {$ifdef FPC}@{$endif} DoChangeImmediatelyFix;
  if Assigned(FSliderAirRotation) then
  begin
    FSliderAirRotation.OnChange := {$ifdef FPC}@{$endif} DoChangeAirRotation;
    FSliderAirRotation.Value := FNavigation.AirRotationControl;
  end;
  if Assigned(FSliderAirMovement) then
    FSliderAirMovement.OnChange := {$ifdef FPC}@{$endif} DoChangeAirMovement;
  if Assigned(FBtnAuto) then
    FBtnAuto.OnClick := {$ifdef FPC}@{$endif} DoClickAuto;
  if Assigned(FBtnDirect) then
    FBtnDirect.OnClick := {$ifdef FPC}@{$endif} DoClickDirect;
  if Assigned(FBtnVelocity) then
    FBtnVelocity.OnClick := {$ifdef FPC}@{$endif} DoClickVelocity;
  if Assigned(FBtnForce) then
    FBtnForce.OnClick := {$ifdef FPC}@{$endif} DoClickForce;
end;

procedure TCameraController.InitDefaults;
var
  SavedDist: Single;
begin
  FNavigation.ChangeTransformation := ctDirect;
  UpdateTransformationButtons;

  FNavigation.Input_LeftStrafe.Assign(keyQ);
  FNavigation.Input_RightStrafe.Assign(keyE);
  FNavigation.CameraFollows := true;
  FNavigation.AimAvatar := aaNone;

  if Assigned(FCheckCameraFollows) then
    FCheckCameraFollows.Checked := false;
  if Assigned(FCheckAimAvatar) then
    FCheckAimAvatar.Checked := false;

  SavedDist := FNavigation.DistanceToAvatarTarget;
  FNavigation.MouseLook := false;
  FNavigation.Init;
  FNavigation.DistanceToAvatarTarget := SavedDist;

  { Подстраховка: если дизайн не задал дистанцию следования (или она
    обнулилась), камера села бы внутрь аватара. Ставим разумные
    значения для вида от третьего лица. }
  if FNavigation.DistanceToAvatarTarget <= 0.01 then
  begin
    FNavigation.DistanceToAvatarTarget := 5.0;
    FNavigation.MinDistanceToAvatarTarget := 2.0;
    FNavigation.MaxDistanceToAvatarTarget := 12.0;
  end;

  {$ifndef CASTLE_UNFINISHED_CHANGE_TRANSFORMATION_BY_FORCE}
  if Assigned(FBtnForce) then
    FBtnForce.Exists := false;
  {$endif}
end;

procedure TCameraController.DragRotate(const Delta: TVector2; AActiveAgent: TPhysicalAgent);
var D:TVector2; SavedFollows:Boolean;
begin
  if (FNavigation=nil) or not FNavigation.Exists then Exit;
  D:=Delta;
  if FNavigation.InvertVerticalMouseLook then D.Y:=-D.Y;
  D.X:=D.X*FNavigation.MouseLookHorizontalSensitivity;
  D.Y:=D.Y*FNavigation.MouseLookVerticalSensitivity;
  SavedFollows:=FNavigation.CameraFollows;
  FNavigation.CameraFollows:=True;
  try TDragNavigationAccess(FNavigation).ProcessMouseLookDelta(D);
  finally FNavigation.CameraFollows:=SavedFollows end;
  if Assigned(AActiveAgent) and Assigned(AActiveAgent.State) then
    AActiveAgent.State.CameraStateValid:=False;
end;

procedure TCameraController.DoChangeCameraFollows(Sender: TObject);
begin
  FNavigation.CameraFollows := false;
  if Assigned(FCheckCameraFollows) then
    FCheckCameraFollows.Checked := false;
end;

procedure TCameraController.DoChangeAimAvatar(Sender: TObject);
begin
  FNavigation.AimAvatar := aaNone;
  if Assigned(FCheckAimAvatar) then
    FCheckAimAvatar.Checked := false;
end;

procedure TCameraController.DoChangeDebugColliders(Sender: TObject);
begin
  if Assigned(FDebugAvatar) and Assigned(FCheckDebugColliders) then
    FDebugAvatar.Exists := FCheckDebugColliders.Checked;
end;

procedure TCameraController.DoChangeImmediatelyFix(Sender: TObject);
begin
  if Assigned(FCheckImmediatelyFix) then
    FNavigation.ImmediatelyFixBlockedCamera := FCheckImmediatelyFix.Checked;
end;

procedure TCameraController.DoChangeAirRotation(Sender: TObject);
begin
  if Assigned(FSliderAirRotation) then
    FNavigation.AirRotationControl := FSliderAirRotation.Value;
end;

procedure TCameraController.DoChangeAirMovement(Sender: TObject);
begin
  if Assigned(FSliderAirMovement) then
    FNavigation.AirMovementControl := FSliderAirMovement.Value;
end;

procedure TCameraController.DoClickAuto(Sender: TObject);
begin
  { placeholder }
end;

procedure TCameraController.DoClickDirect(Sender: TObject);
begin
  { placeholder }
end;

procedure TCameraController.DoClickVelocity(Sender: TObject);
begin
  { placeholder }
end;

procedure TCameraController.DoClickForce(Sender: TObject);
begin
  { placeholder }
end;

procedure TCameraController.UpdateTransformationButtons;
begin
  if Assigned(FBtnAuto) then
    FBtnAuto.Pressed := FNavigation.ChangeTransformation = ctAuto;
  if Assigned(FBtnDirect) then
    FBtnDirect.Pressed := FNavigation.ChangeTransformation = ctDirect;
  if Assigned(FBtnVelocity) then
    FBtnVelocity.Pressed := FNavigation.ChangeTransformation = ctVelocity;
  {$ifdef CASTLE_UNFINISHED_CHANGE_TRANSFORMATION_BY_FORCE}
  if Assigned(FBtnForce) then
    FBtnForce.Pressed := FNavigation.ChangeTransformation = ctForce;
  {$endif}
end;

end.
