unit GameRidePanel;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, CastleUIControls, CastleControls, CastleKeysMouse, CastleVectors,
  GameMenuTheme;
type
  TRidePanelScroll = class(TCastleScrollView)
  private
    FManualUntil:QWord;
    function GetAutoCenterAllowed:Boolean;
  public
    function Press(const Event:TInputPressRelease):Boolean;override;
    function Motion(const Event:TInputMotion):Boolean;override;
    property AutoCenterAllowed:Boolean read GetAutoCenterAllowed;
  end;

  { Only this header captures the dismissal gesture. Drags over the map and
    rider list retain their own pan/scroll semantics. }
  TRidePanelHeader = class(TMenuPanel)
  private
    FTitle:TCastleLabel;
    FGrip:TCastleRectangleControl;
    FMinimize:TMenuButton;
    FFinger:Int64;
    FOrigin:TVector2;
    procedure ResetGesture;
    procedure Minimize(Sender:TObject);
  public
    OnMinimize:TNotifyEvent;
    constructor Create(AOwner:TComponent);override;
    procedure Resize;override;
    function Press(const Event:TInputPressRelease):Boolean;override;
    function Motion(const Event:TInputMotion):Boolean;override;
    function Release(const Event:TInputPressRelease):Boolean;override;
  end;
implementation
uses Math, SysUtils, UiTranslations;

function TRidePanelScroll.GetAutoCenterAllowed:Boolean;
begin Result:=GetTickCount64>=FManualUntil end;

function TRidePanelScroll.Press(const Event:TInputPressRelease):Boolean;
begin
  if Event.EventType in [itMouseButton,itMouseWheel]then
    FManualUntil:=GetTickCount64+15000;
  Result:=inherited;
end;

function TRidePanelScroll.Motion(const Event:TInputMotion):Boolean;
begin
  if buttonLeft in Event.Pressed then FManualUntil:=GetTickCount64+15000;
  Result:=inherited;
end;

constructor TRidePanelHeader.Create(AOwner:TComponent);
begin
  inherited;FFinger:=-1;Width:=210;Height:=34;
  FGrip:=TCastleRectangleControl.Create(Self);FGrip.Width:=32;FGrip.Height:=3;
  FGrip.Color:=MenuMuted;FGrip.CapturesEvents:=False;
  FGrip.Anchor(hpMiddle,-12);FGrip.Anchor(vpTop,-4);InsertFront(FGrip);
  FTitle:=TMenuLabel.Create(Self);FTitle.FontSize:=11;FTitle.CapturesEvents:=False;
  BindUiText(FTitle,'Map & riders');FTitle.Anchor(hpLeft,8);FTitle.Anchor(vpBottom,5);
  InsertFront(FTitle);
  FMinimize:=TMenuButton.Create(Self);FMinimize.Name:='MinimizeRidePanel';
  FMinimize.AutoIcon:=False;FMinimize.AutoSize:=False;
  FMinimize.Width:=34;FMinimize.Height:=32;FMinimize.FontSize:=20;
  {$ifdef ANDROID}
  { Keep the dismissal target thumb-sized even on a narrow phone. }
  Height:=48;FMinimize.Width:=48;FMinimize.Height:=48;
  FTitle.FontSize:=12;FTitle.Anchor(vpBottom,10);
  {$endif}
  FMinimize.Caption:='−';FMinimize.Style:=mbGhost;
  FMinimize.Anchor(hpRight,-2);FMinimize.Anchor(vpMiddle);
  FMinimize.OnClick:=@Minimize;InsertFront(FMinimize);Resize;
end;

procedure TRidePanelHeader.ResetGesture;
begin
  FFinger:=-1;
  if Container<>nil then Container.ReleaseCapture(Self);
end;

procedure TRidePanelHeader.Resize;
begin
  inherited;ResetGesture;
  if (FTitle<>nil)and(FMinimize<>nil)then
    FTitle.MaxWidth:=Max(40,Width-FMinimize.Width-16);
end;

procedure TRidePanelHeader.Minimize(Sender:TObject);
begin
  ResetGesture;
  if Assigned(OnMinimize)then OnMinimize(Self);
end;

function TRidePanelHeader.Press(const Event:TInputPressRelease):Boolean;
begin
  Result:=inherited;if Result then Exit;
  if Event.IsMouseWheel(mwDown)then begin Minimize(Self);Exit(True) end;
  if Event.IsMouseButton(buttonLeft)then begin
    if FFinger<0 then begin FFinger:=Event.FingerIndex;FOrigin:=Event.Position end;
    Result:=True;
  end;
end;

function TRidePanelHeader.Motion(const Event:TInputMotion):Boolean;
var Delta:TVector2;
begin
  Result:=inherited;
  if FFinger<>Event.FingerIndex then Exit;
  if not(buttonLeft in Event.Pressed)then begin ResetGesture;Exit(True) end;
  Delta:=(FOrigin-Event.Position)/Max(0.1,UIScale);
  if (Delta.Y>=28) and (Delta.Y>Abs(Delta.X)*1.2)then Minimize(Self);
  Result:=True;
end;

function TRidePanelHeader.Release(const Event:TInputPressRelease):Boolean;
begin
  Result:=inherited;
  if Event.IsMouseButton(buttonLeft)and(FFinger=Event.FingerIndex)then begin
    ResetGesture;Result:=True;
  end;
end;
end.
