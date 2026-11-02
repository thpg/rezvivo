unit GameRideMenuHeader;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, CastleUIControls, CastleControls, GameMenuTheme;
type
  { Shared selection and launch controls for real and baked worlds. }
  TRideMenuHeader = class(TMenuPanel)
  private
    FTitle, FInfo: TCastleLabel;
    FStart: TMenuButton;
    FTitleText,FInfoText:String;
    FLayoutWidth,FLayoutScale:Single;
    procedure Layout;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Resize; override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean); override;
    procedure SetSelection(const Title, Info: String; Ready: Boolean);
    procedure SetRideState(ActiveRide, SameRoute: Boolean);
    property StartButton: TMenuButton read FStart;
  end;
implementation
uses GameTravelUI, Math, CastleVectors, CastleColors, UiTranslations;
constructor TRideMenuHeader.Create(AOwner: TComponent);
begin
  inherited;
  WidthFraction:=1; Height:=86; Color:=MenuSurface;
  FTitle:=TMenuLabel.Create(Self);FTitle.Color:=MenuText;FTitle.CustomFont:=MenuFont(True);FTitle.Name:='SelectedRideTitle';InsertFront(FTitle);
  FInfo:=TMenuLabel.Create(Self);FInfo.Color:=Vector4(0.69,0.78,0.84,1);InsertFront(FInfo);
  FStart:=TMenuButton.Create(Self);FStart.Name:='StartSelectedRide';FStart.AutoSize:=False;
  FStart.AutoIcon:=False;FStart.Enabled:=False;InsertFront(FStart);
  SetRideState(False,False);Layout;
end;
procedure TRideMenuHeader.Layout;
var S,W:Single;ShortLayout,Narrow:Boolean;
begin
  S:=Max(0.65,Min(1,UIScale));W:=EffectiveWidth;Narrow:=W<520/S;
  FLayoutWidth:=W;FLayoutScale:=UIScale;
  ShortLayout:=(Container<>nil) and (Container.UnscaledHeight<560);
  if Narrow then begin
    Height:=136/S;
    FTitle.FontSize:=19/S;FTitle.MaxWidth:=Max(40,W-32/S);
    FTitle.Anchor(hpLeft,16/S);FTitle.Anchor(vpTop,-10/S);
    FTitle.Caption:=MenuSummary(FTitleText,FTitle.Font,FTitle.MaxWidth*UIScale,2);
    FInfo.FontSize:=12/S;FInfo.MaxWidth:=FTitle.MaxWidth;
    FInfo.Anchor(hpLeft,16/S);FInfo.Anchor(vpTop,-58/S);
    FInfo.Caption:=MenuEllipsis(FInfoText,FInfo.Font,FInfo.MaxWidth*UIScale);
    FStart.Width:=Max(40,W-28/S);FStart.Height:=44/S;FStart.FontSize:=16/S;
    FStart.Anchor(hpLeft,14/S);FStart.Anchor(vpBottom,10/S);
    Exit;
  end;
  if ShortLayout then Height:=62/S else Height:=86/S;
  FStart.Width:=210/S;FStart.Height:=44/S;FStart.FontSize:=17/S;
  FStart.Anchor(hpRight,-14/S);FStart.Anchor(vpMiddle);
  FTitle.FontSize:=22/S;FTitle.Anchor(hpLeft,16/S);FTitle.Anchor(vpTop,-14/S);
  FTitle.MaxWidth:=Max(80,EffectiveWidth-250/S);
  FInfo.FontSize:=14/S;FInfo.Anchor(hpLeft,16/S);FInfo.Anchor(vpTop,-49/S);
  FInfo.MaxWidth:=FTitle.MaxWidth;
  if ShortLayout then begin
    FTitle.FontSize:=18/S;FTitle.Anchor(vpTop,-7/S);
    FInfo.FontSize:=12/S;FInfo.Anchor(vpTop,-36/S);
  end;
  FTitle.Caption:=MenuEllipsis(FTitleText,FTitle.Font,FTitle.MaxWidth*UIScale);
  FInfo.Caption:=MenuEllipsis(FInfoText,FInfo.Font,FInfo.MaxWidth*UIScale);
end;
procedure TRideMenuHeader.Resize;
begin inherited;Layout;end;
procedure TRideMenuHeader.Update(const SecondsPassed:Single;var HandleInput:Boolean);
begin
  inherited;
  { Parent scroll canvases settle after the window's Resize traversal. }
  if (Abs(EffectiveWidth-FLayoutWidth)>0.1) or
    (Abs(UIScale-FLayoutScale)>0.001) then Layout;
end;
procedure TRideMenuHeader.SetSelection(const Title,Info:String;Ready:Boolean);
begin FTitleText:=Title;FInfoText:=Info;FStart.Enabled:=Ready;Layout;end;
procedure TRideMenuHeader.SetRideState(ActiveRide,SameRoute:Boolean);
begin
  if ActiveRide then begin
    if SameRoute then BindUiText(FStart,'Restart this route')
    else BindTravelText(FStart, 'Start another ride');
    FStart.Style:=mbSecondary;
  end else begin
    BindTravelText(FStart, 'Start ride');
    FStart.Style:=mbPrimary;
  end;

end;
end.
