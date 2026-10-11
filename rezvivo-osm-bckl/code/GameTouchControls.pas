unit GameTouchControls;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, CastleUIControls, CastleControls, CastleKeysMouse, CastleVectors,
  GameTravel, GameMenuTheme;
type
  { Captured per finger by CGE, independent of keyboard state and other thumbs. }
  TTravelTouchPad = class(TCastleUserInterface)
  private
    FFinger: Int64;
    FAxis, FOrigin, FLook: TVector2;
    FLabel: TCastleLabel;
    procedure MoveTo(const Position:TVector2);
  public
    Stick, LookArea: Boolean;
    constructor Create(AOwner:TComponent);override;
    procedure Reset;
    procedure SetCaption(const Value:string);
    function Held:Boolean;
    function TakeLook:TVector2;
    function Press(const Event:TInputPressRelease):Boolean;override;
    function Release(const Event:TInputPressRelease):Boolean;override;
    function Motion(const Event:TInputMotion):Boolean;override;
    procedure Render;override;
    property Axis:TVector2 read FAxis;
  end;
  TTravelTouchControls = class(TCastleUserInterface)
  private
    FMode:TTravelMode;
    FEnabled,FFlying:Boolean;
    FStick,FPrimary,FSecondary,FLook:TTravelTouchPad;
    FCamera:TMenuButton;
  public
    constructor Create(AOwner:TComponent);override;
    procedure Configure(Mode:TTravelMode;Available,CanMove,FreeCamera:Boolean);
    procedure Reset;
    procedure Resize;override;
    function Movement:TVector2;
    function PowerAxis:Single;
    function VerticalAxis:Single;
    function Fast:Boolean;
    function Braking:Boolean;
    function TakeLook:TVector2;
    property Supported:Boolean read FEnabled;
    property CameraButton:TMenuButton read FCamera;
  end;
implementation
uses SysUtils,Math,CastleColors,CastleRectangles,CastleGLUtils,UiTranslations;

constructor TTravelTouchPad.Create(AOwner:TComponent);
begin
  inherited;
  FFinger:=-1;Width:=64;Height:=64;
  FLabel:=TMenuLabel.Create(Self);FLabel.FontSize:=16;
  FLabel.Color:=White;
  FLabel.Anchor(hpMiddle);FLabel.Anchor(vpMiddle);InsertFront(FLabel);
end;
procedure TTravelTouchPad.SetCaption(const Value:string);
begin FLabel.Caption:=UiText(Value) end;
procedure TTravelTouchPad.Reset;
begin
  FFinger:=-1;FAxis:=TVector2.Zero;FLook:=TVector2.Zero;
  if Container<>nil then Container.ReleaseCapture(Self);
end;
function TTravelTouchPad.Held:Boolean;
begin Result:=FFinger>=0 end;
function TTravelTouchPad.TakeLook:TVector2;
begin Result:=FLook;FLook:=TVector2.Zero end;
procedure TTravelTouchPad.MoveTo(const Position:TVector2);
var V:TVector2;L:Single;
begin
  V:=(Position-FOrigin)/Max(1,RenderRect.Width*0.33);L:=V.Length;
  if L<=0.12 then FAxis:=TVector2.Zero
  else FAxis:=V*(Min(1,(L-0.12)/0.88)/L);
end;
function TTravelTouchPad.Press(const Event:TInputPressRelease):Boolean;
begin
  Result:=inherited;
  if Result or not Event.IsMouseButton(buttonLeft) then Exit;
  if FFinger>=0 then Exit(True);
  FFinger:=Event.FingerIndex;
  FOrigin:=RenderRect.Center;
  if Stick then MoveTo(Event.Position);
  Result:=True;
end;
function TTravelTouchPad.Release(const Event:TInputPressRelease):Boolean;
begin
  Result:=inherited;
  if Event.IsMouseButton(buttonLeft) and (FFinger=Event.FingerIndex) then begin
    Reset;Result:=True;
  end;
end;
function TTravelTouchPad.Motion(const Event:TInputMotion):Boolean;
begin
  Result:=inherited;
  if FFinger<>Event.FingerIndex then Exit;
  if not (buttonLeft in Event.Pressed) then begin Reset;Exit(True) end;
  if LookArea then FLook:=FLook+(Event.Position-Event.OldPosition)/Max(0.1,UIScale)
  else if Stick then MoveTo(Event.Position);
  Result:=True;
end;
procedure TTravelTouchPad.Render;
var R:TFloatRectangle;P:TVector2;C:TCastleColor;
begin
  inherited;
  if LookArea then Exit;
  R:=RenderRect;P:=R.Center;
  C:=Vector4(0.035,0.07,0.09,0.48);
  if Held then C:=Vector4(0.09,0.25,0.30,0.72);
  DrawCircle(P,R.Width*0.48,R.Height*0.48,C);
  DrawCircleOutline(P,R.Width*0.48,R.Height*0.48,Vector4(0.85,0.95,1,0.58),1.5*UIScale);
  if Stick then begin
    P:=P+FAxis*(R.Width*0.30);
    DrawCircle(P,R.Width*0.18,R.Height*0.18,Vector4(0.83,0.95,1,0.70));
  end;
end;
constructor TTravelTouchControls.Create(AOwner:TComponent);
begin
  inherited;FullSize:=True;
  {$ifdef ANDROID}FEnabled:=True;{$else}
  FEnabled:=GetEnvironmentVariable('REZVIVO_TEST_TOUCH')='1';
  {$endif}
  Exists:=False;
  FLook:=TTravelTouchPad.Create(Self);FLook.Name:='TouchLook';FLook.LookArea:=True;InsertBack(FLook);
  FStick:=TTravelTouchPad.Create(Self);FStick.Name:='TouchMove';FStick.Stick:=True;InsertFront(FStick);
  FPrimary:=TTravelTouchPad.Create(Self);FPrimary.Name:='TouchAction';InsertFront(FPrimary);
  FSecondary:=TTravelTouchPad.Create(Self);FSecondary.Name:='TouchBrake';InsertFront(FSecondary);
  FCamera:=TMenuButton.Create(Self);FCamera.Name:='TouchCamera';FCamera.AutoIcon:=False;
  FCamera.AutoSize:=False;FCamera.Width:=88;FCamera.Height:=44;
  BindUiText(FCamera,'Camera');InsertFront(FCamera);
end;
procedure TTravelTouchControls.Reset;
begin FStick.Reset;FPrimary.Reset;FSecondary.Reset;FLook.Reset end;
procedure TTravelTouchControls.Configure(Mode:TTravelMode;Available,CanMove,FreeCamera:Boolean);
var Show,Changed:Boolean;
begin
  if not FEnabled then Exit;
  Show:=FEnabled and Available;
  Changed:=(FMode<>Mode) or (FFlying<>FreeCamera) or (Exists<>Show);
  if Changed or (FStick.Exists<>CanMove) then Reset;
  FMode:=Mode;FFlying:=FreeCamera;Exists:=Show;
  FStick.Exists:=CanMove;FPrimary.Exists:=CanMove;FSecondary.Exists:=CanMove and ((Mode<>travelWalk) or FreeCamera);
  FCamera.Exists:=Mode<>travelFlight;
  if not Changed then Exit;
  if FreeCamera then begin FPrimary.SetCaption('Up');FSecondary.SetCaption('Down') end
  else case Mode of
    travelWalk:FPrimary.SetCaption('Run');
    travelBicycle:begin FPrimary.SetCaption('+ W');FSecondary.SetCaption('Brake') end;
  end;
end;
procedure TTravelTouchControls.Resize;
var Size,Margin:Single;
begin
  inherited;
  { Logical units include physical-DPI scaling; never grow with a wide screen. }
  Size:=Min(144,Min(EffectiveWidth*0.34,EffectiveHeight*0.40));
  Size:=Max(80,Size);Margin:=20;
  FStick.Width:=Size;FStick.Height:=Size;
  FStick.Anchor(hpLeft,20);FStick.Anchor(vpBottom,Margin);
  FPrimary.Anchor(hpRight,-20);FPrimary.Anchor(vpBottom,Margin);
  FSecondary.Anchor(hpRight,-92);FSecondary.Anchor(vpBottom,Margin);
  FCamera.Anchor(hpRight,-20);FCamera.Anchor(vpBottom,Margin+80);
  FLook.Width:=EffectiveWidth*0.52;FLook.Height:=Max(44,EffectiveHeight-200);
  FLook.Anchor(hpRight);FLook.Anchor(vpBottom,100);
end;
function TTravelTouchControls.Movement:TVector2;
begin if Exists and FStick.Exists then Result:=FStick.Axis else Result:=TVector2.Zero end;
function TTravelTouchControls.PowerAxis:Single;
begin
  Result:=0;if not Exists or FFlying then Exit;
  if FPrimary.Held then Result:=1;
  if FSecondary.Held then Result:=-1;
end;
function TTravelTouchControls.VerticalAxis:Single;
begin Result:=0;if Exists and FFlying then Result:=Ord(FPrimary.Held)-Ord(FSecondary.Held) end;
function TTravelTouchControls.Fast:Boolean;
begin Result:=Exists and FPrimary.Held and (FMode=travelWalk) and not FFlying end;
function TTravelTouchControls.Braking:Boolean;
begin Result:=Exists and FSecondary.Held and (FMode=travelBicycle) and not FFlying end;
function TTravelTouchControls.TakeLook:TVector2;
begin Result:=FLook.TakeLook end;
end.
