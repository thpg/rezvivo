unit GameMenuDialog;
{$mode objfpc}{$H+}
interface
uses Classes, CastleUIControls, CastleControls, CastleKeysMouse, GameMenuTheme;
type
  { A touch-accessible dialog: only the body scrolls, never the exit action.
    Add body controls in reading order. Labels wrap and action rows reflow. }
  TMenuDialog = class(TCastleRectangleControl)
  private
    FPanel:TMenuPanel;
    FTitle:TMenuLabel;
    FClose:TMenuButton;
    FScroll:TMenuScrollView;
    FContent:TCastleUserInterface;
    FArranging:Boolean;
    procedure DefaultClose(Sender:TObject);
  public
    PreferredWidth,PreferredHeight:Single;
    constructor Create(AOwner:TComponent);override;
    procedure Show(AContainer:TCastleContainer);
    procedure Arrange;
    procedure Resize;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    function Press(const Event:TInputPressRelease):Boolean;override;
    function Release(const Event:TInputPressRelease):Boolean;override;
    function Motion(const Event:TInputMotion):Boolean;override;
    property Title:TMenuLabel read FTitle;
    property CloseButton:TMenuButton read FClose;
    property Content:TCastleUserInterface read FContent;
    property Scroll:TMenuScrollView read FScroll;
  end;
implementation
uses Math,CastleVectors,UiTranslations;

constructor TMenuDialog.Create(AOwner:TComponent);
begin
  inherited;FullSize:=True;Color:=Vector4(0.01,0.025,0.04,0.94);
  PreferredWidth:=650;PreferredHeight:=520;
  FPanel:=TMenuPanel.Create(Self);FPanel.Anchor(hpMiddle);FPanel.Anchor(vpMiddle);InsertFront(FPanel);
  FTitle:=TMenuLabel.Create(Self);FTitle.FontSize:=24;
  FTitle.Anchor(hpLeft,16);FTitle.Anchor(vpTop,-20);FTitle.CapturesEvents:=False;FPanel.InsertFront(FTitle);
  FClose:=TMenuButton.Create(Self);FClose.AutoIcon:=False;FClose.FontSize:=16;
  FClose.MinHeight:=44;BindUiText(FClose,'Close');FClose.OnClick:=@DefaultClose;
  FClose.Anchor(hpRight,-12);FClose.Anchor(vpTop,-12);FPanel.InsertFront(FClose);
  FScroll:=TMenuScrollView.Create(Self);FScroll.FullSize:=True;
  FScroll.Border.Left:=16;FScroll.Border.Right:=16;FScroll.Border.Top:=76;FScroll.Border.Bottom:=16;
  FScroll.ScrollArea.AutoSizeToChildren:=False;
  FScroll.ScrollArea.WidthFraction:=1;FPanel.InsertBack(FScroll);
  FContent:=TCastleUserInterface.Create(Self);
  FContent.Anchor(vpTop);FScroll.ScrollArea.InsertFront(FContent);
end;

procedure TMenuDialog.DefaultClose(Sender:TObject);
begin Exists:=False end;

procedure TMenuDialog.Show(AContainer:TCastleContainer);
begin
  if AContainer=nil then Exit;
  { Embedded pages may be taller than their visible scroll viewport. Attach
    popups to the window, retaining their page as owner for lifetime safety. }
  if Parent<>nil then Parent.RemoveControl(Self);
  if Container<>nil then Container.Controls.Remove(Self);
  AContainer.Controls.InsertFront(Self);Exists:=True;Arrange;
end;

procedure TMenuDialog.Arrange;
var W,Y:Single;I,J:Integer;C,D:TCastleUserInterface;
begin
  if FArranging or(FContent=nil)or(EffectiveWidth<=0)or(EffectiveHeight<=0)then Exit;
  FArranging:=True;
  try
    FPanel.Width:=Max(1,Min(PreferredWidth,EffectiveWidth-16));
    FPanel.Height:=Max(1,Min(PreferredHeight,EffectiveHeight-16));
    FTitle.MaxWidth:=Max(1,FPanel.Width-FClose.EffectiveWidth-48);
    FScroll.Border.Top:=Max(68,Min(FPanel.Height*0.4,28+FTitle.EffectiveHeight));
    W:=Max(1,FScroll.EffectiveWidthForChildren);FContent.Width:=W;Y:=0;
    for I:=0 to FContent.ControlsCount-1 do begin
      C:=FContent.Controls[I];if not C.Exists then Continue;
      if C is TCastleLabel then TCastleLabel(C).MaxWidth:=W
      else if C is TMenuFlow then begin C.WidthFraction:=0;C.Width:=W;TMenuFlow(C).Arrange end
      else if C is TCastleVerticalGroup then begin
        C.AutoSizeToChildren:=False;TCastleVerticalGroup(C).AutoSizeWidth:=False;C.WidthFraction:=0;C.Width:=W;
        for J:=0 to C.ControlsCount-1 do begin
          D:=C.Controls[J];D.WidthFraction:=0;
          if D is TCastleButton then D.Width:=W;
        end;
      end
      else if C is TCastleEdit then C.Width:=W;
      C.Anchor(hpLeft);C.Anchor(vpTop,-Y);Y:=Y+C.EffectiveHeight+16;
    end;
    FContent.Height:=Max(1,Y);FScroll.ScrollArea.Height:=FContent.Height;
  finally FArranging:=False end;
end;
procedure TMenuDialog.Resize;
begin inherited;Arrange end;
procedure TMenuDialog.Update(const SecondsPassed:Single;var HandleInput:Boolean);
begin inherited;Arrange end;
function TMenuDialog.Press(const Event:TInputPressRelease):Boolean;
begin
  Result:=inherited;
  if not Result and Event.IsKey(keyEscape)then FClose.DoClick;
  Result:=True;
end;
function TMenuDialog.Release(const Event:TInputPressRelease):Boolean;
begin inherited;Result:=True end;
function TMenuDialog.Motion(const Event:TInputMotion):Boolean;
begin inherited;Result:=True end;
end.
