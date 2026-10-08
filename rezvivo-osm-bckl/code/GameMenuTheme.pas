unit GameMenuTheme;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses UiTranslations, Classes, SysUtils, CastleUIControls, CastleControls, CastleColors, CastleFonts, CastleVectors, CastleRectangles;

const
  MenuBackground: TCastleColor = (X:0.043; Y:0.063; Z:0.078; W:1);
  MenuSurface: TCastleColor = (X:0.075; Y:0.114; Z:0.145; W:1);
  MenuBorder: TCastleColor = (X:0.149; Y:0.212; Z:0.255; W:1);
  MenuText: TCastleColor = (X:0.929; Y:0.953; Z:0.965; W:1);
  MenuMuted: TCastleColor = (X:0.604; Y:0.682; Z:0.733; W:1);
  MenuAccent: TCastleColor = (X:0.333; Y:0.851; Z:0.918; W:1);

type
  TMenuButtonStyle = (mbSecondary, mbPrimary, mbDanger, mbGhost);
  TMenuLabel = class(TCastleLabel)
  public
    constructor Create(AOwner:TComponent); override;
  end;
  TMenuEdit = class(TCastleEdit)
  public
    constructor Create(AOwner:TComponent); override;
    procedure Render;override;
  end;
  TMenuScrollView=class(TCastleScrollView)
  public
    constructor Create(AOwner:TComponent);override;
  end;
  TMenuPanel = class(TCastleRectangleControl)
  public
    Radius:Single;
    Stroke:TCastleColor;
    constructor Create(AOwner:TComponent); override;
    procedure Render; override;
  end;
  TMenuGlyphKind=(mgHome,mgWorld,mgMountain,mgTraining,mgHistory,mgSettings,mgArrow,mgBicycle,mgCalendar,mgAssistant);
  TMenuGlyph=class(TCastleUserInterface)
  public
    Kind:TMenuGlyphKind;
    Color:TCastleColor;
    constructor Create(AOwner:TComponent); override;
    procedure Render; override;
  end;
  { Keep the engine button's events, toggle, keyboard and disabled semantics.
    Only its appearance changes; compact controls retain their original size. }
  TMenuButton = class(TCastleButton)
  private
    FLastCaption: String;
    FAutoIcon: Boolean;
    FStyle:TMenuButtonStyle;
    procedure SetStyle(const Value:TMenuButtonStyle);
    procedure SyncIcon;
  public
    procedure DoClick; override;
    constructor Create(AOwner: TComponent); override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    procedure Render; override;
  published
    property Style:TMenuButtonStyle read FStyle write SetStyle default mbSecondary;
    property AutoIcon: Boolean read FAutoIcon write FAutoIcon default True;
  end;

  { A toolbar that wraps its existing controls without replacing their events. }
  TMenuFlow = class(TCastleUserInterface)
  private
    FSpacing: Single;
    FArranging: Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Arrange;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    property Spacing: Single read FSpacing write FSpacing;
  end;

function MenuFont(const Bold:Boolean=False):TCastleAbstractFont;
procedure DrawMenuPanel(const R:TFloatRectangle;const Radius:Single;const Color:TCastleColor);
procedure StyleMenuButton(const B: TCastleButton);
procedure StyleMenuButtons(const Root: TCastleUserInterface);
procedure StyleMenuFields(const Root:TCastleUserInterface);
procedure SelectMenuButton(const B: TCastleButton; const Selected: Boolean);
function MenuEllipsis(const Text: String; const Font: TCastleAbstractFont;
  const PixelWidth: Single): String;
function MenuSummary(const Text: String; const Font: TCastleAbstractFont;
  const PixelWidth: Single; const MaxLines: Integer): String;

implementation
uses Math, CastleGLUtils, CastleImages, CastleRenderOptions, CastleComponentSerialize, GameAudio;

var FontOwner:TComponent;
    RegularFont,BoldFont:TCastleFont;

function MenuFont(const Bold:Boolean):TCastleAbstractFont;
  function Load(const Url:String):TCastleFont;
  var I:Integer;Latin:UnicodeString;
  begin
    Result:=TCastleFont.Create(FontOwner);
    Result.OptimalSize:=48;
    Latin:='';for I:=$00A0 to $017F do Latin:=Latin+WideChar(I);
    Result.LoadCharacters:=UTF8Encode(Latin)+'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюяіІїЇєЄґҐ' +
      '←→↑↓×−–—…·°²³©✓✕☆★⚙‹›♥Δ•‘’“”';
    Result.Url:='castle-data:/menu/fonts/'+Url;
    { Loading synchronizes Size with OptimalSize; keep the UI's base size
      independent of the higher-resolution glyph atlas. }
    Result.Size:=20;
  end;
begin
  if FontOwner=nil then FontOwner:=TComponent.Create(nil);
  if Bold then begin
    if BoldFont=nil then BoldFont:=Load('DejaVuSans-Bold.ttf');Result:=BoldFont;
  end else begin
    if RegularFont=nil then RegularFont:=Load('DejaVuSans.ttf');Result:=RegularFont;
  end;
end;

constructor TMenuLabel.Create(AOwner:TComponent);
begin inherited;CustomFont:=MenuFont;Color:=MenuText;Outline:=0;end;

constructor TMenuEdit.Create(AOwner:TComponent);
begin
  inherited;CustomFont:=MenuFont;BackgroundColor:=MenuSurface;
  FocusedColor:=MenuText;UnfocusedColor:=MenuText;PlaceholderColor:=MenuMuted;
  Frame:=False;PaddingHorizontal:=12;PaddingVertical:=9;
  Border.AllSides:=1;BorderColor:=MenuBorder;
end;

procedure TMenuEdit.Render;
begin
  inherited;
  if Focused and Enabled then DrawRectangleOutline(RenderRect,MenuAccent,Max(1,UIScale));
end;

procedure StyleMenuFields(const Root:TCastleUserInterface);
var I:Integer;E:TCastleEdit;
begin
  if Root is TCastleEdit then begin
    E:=TCastleEdit(Root);E.CustomFont:=MenuFont;E.BackgroundColor:=MenuSurface;
    E.FocusedColor:=MenuText;E.UnfocusedColor:=MenuText;E.PlaceholderColor:=MenuMuted;
    E.Frame:=False;E.Border.AllSides:=1;E.BorderColor:=MenuBorder;
  end;
  for I:=0 to Root.ControlsCount-1 do StyleMenuFields(Root.Controls[I]);
end;

procedure DrawMenuPanel(const R:TFloatRectangle;const Radius:Single;const Color:TCastleColor);
var P:array[0..35]of TVector2;I,J,K:Integer;A,X,Y,Rad:Single;
begin
  if(Color.W<=0)or(R.Width<=0)or(R.Height<=0)then Exit;
  Rad:=Min(Radius,Min(R.Width,R.Height)*0.5);
  if Rad<0.5 then begin DrawRectangle(R,Color);Exit;end;
  K:=0;
  for I:=0 to 3 do begin
    case I of
      0:begin X:=R.Right-Rad;Y:=R.Top-Rad;end;
      1:begin X:=R.Left+Rad;Y:=R.Top-Rad;end;
      2:begin X:=R.Left+Rad;Y:=R.Bottom+Rad;end;
      else begin X:=R.Right-Rad;Y:=R.Bottom+Rad;end;
    end;
    for J:=0 to 8 do begin
      A:=(I+J/8)*Pi*0.5;P[K]:=Vector2(X+Cos(A)*Rad,Y+Sin(A)*Rad);Inc(K);
    end;
  end;
  DrawPrimitive2D(pmTriangleFan,P,Color);
end;

constructor TMenuScrollView.Create(AOwner:TComponent);
var Img:TRGBAlphaImage;
begin
  inherited;ScrollBarWidth:=6;
  Img:=TRGBAlphaImage.Create(1,1);Img.Clear(Vector4Byte(255,255,255,255));ScrollbarFrame.Image:=Img;
  ScrollbarFrame.Color:=Vector4(0.075,0.114,0.145,1);
  Img:=TRGBAlphaImage.Create(1,1);Img.Clear(Vector4Byte(255,255,255,255));ScrollbarSlider.Image:=Img;
  ScrollbarSlider.Color:=Vector4(0.24,0.34,0.40,1);
end;

constructor TMenuPanel.Create(AOwner:TComponent);
begin inherited;Radius:=12;Color:=MenuSurface;Stroke:=MenuBorder;end;
procedure TMenuPanel.Render;
begin
  if Stroke.W>0 then begin
    DrawMenuPanel(RenderRect,Radius*UIScale,Stroke);
    DrawMenuPanel(RenderRect.Grow(-Max(1,UIScale)),Max(0,Radius*UIScale-1),Color);
  end else DrawMenuPanel(RenderRect,Radius*UIScale,Color);
end;

constructor TMenuGlyph.Create(AOwner:TComponent);
begin inherited;Width:=24;Height:=24;Color:=MenuMuted;end;
procedure TMenuGlyph.Render;
var R:TFloatRectangle;P:array of TVector2;I:Integer;A:Single;
  procedure Line(const XY:array of Single);
  var J:Integer;
  begin
    SetLength(P,Length(XY)div 2);
    for J:=0 to High(P)do P[J]:=Vector2(R.Left+XY[J*2]*R.Width/24,R.Bottom+(24-XY[J*2+1])*R.Height/24);
    DrawPrimitive2D(pmLineStrip,P,Color,bsSrcAlpha,bdOneMinusSrcAlpha,False,Max(1.4,1.6*UIScale));
  end;
begin
  R:=RenderRect;
  case Kind of
    mgHome:begin Line([3,10,12,3,21,10]);Line([5,9,5,21,10,21,10,14,14,14,14,21,19,21,19,9]);end;
    mgWorld:begin
      DrawCircleOutline(Vector2(R.Left+R.Width/2,R.Bottom+R.Height/2),R.Width*0.40,R.Height*0.40,Color,1.5*UIScale);
      DrawCircleOutline(Vector2(R.Left+R.Width/2,R.Bottom+R.Height/2),R.Width*0.17,R.Height*0.40,Color,1.5*UIScale);
      Line([3,9,21,9]);Line([3,15,21,15]);
    end;
    mgMountain:begin Line([2,20,10,5,18,20,2,20]);Line([15,14,18,9,23,20,18,20]);Line([7,11,10,13,12,10]);end;
    mgTraining:begin Line([3,21,3,3]);Line([3,21,22,21]);Line([7,17,7,13,10,13,10,17]);Line([13,17,13,9,16,9,16,17]);Line([19,17,19,5,22,5,22,17]);end;
    mgCalendar:begin
      Line([3,5,21,5,21,21,3,21,3,5]);Line([3,10,21,10]);
      Line([7,2,7,7]);Line([17,2,17,7]);Line([7,14,10,17,17,12]);
    end;
    mgHistory:begin
      DrawCircleOutline(Vector2(R.Left+R.Width*0.52,R.Bottom+R.Height*0.50),R.Width*0.37,R.Height*0.37,Color,1.5*UIScale);
      Line([12,6,12,12,17,15]);Line([2,3,2,9,8,9]);
    end;
    mgSettings:begin
      for I:=0 to 7 do begin A:=I*Pi/4;Line([12+7*Cos(A),12+7*Sin(A),12+10*Cos(A),12+10*Sin(A)]);end;
      DrawCircleOutline(Vector2(R.Left+R.Width/2,R.Bottom+R.Height/2),R.Width*0.30,R.Height*0.30,Color,1.5*UIScale);
      DrawCircleOutline(Vector2(R.Left+R.Width/2,R.Bottom+R.Height/2),R.Width*0.11,R.Height*0.11,Color,1.5*UIScale);
    end;
    mgBicycle:begin
      DrawCircleOutline(Vector2(R.Left+R.Width*0.24,R.Bottom+R.Height*0.27),R.Width*0.20,R.Height*0.20,Color,1.5*UIScale);
      DrawCircleOutline(Vector2(R.Left+R.Width*0.80,R.Bottom+R.Height*0.27),R.Width*0.20,R.Height*0.20,Color,1.5*UIScale);
      Line([6,17,10,8,15,17,6,17,16,9,19,17]);Line([8,7,12,7]);Line([16,4,18,4,19,6]);Line([17,5,19,17]);
    end;
    mgArrow:begin Line([4,12,20,12]);Line([14,6,20,12,14,18]);end;
    mgAssistant:begin
      Line([4,3,20,3,22,5,22,15,20,17,10,17,4,22,4,17,2,15,2,5,4,3]);
      Line([6,8,18,8]);Line([6,12,14,12]);
    end;
  end;
end;

procedure StyleMenuButton(const B:TCastleButton);
begin
  B.CustomBackground:=True;
  B.CustomFont:=MenuFont;
  B.CustomColorNormal:=Vector4(0.105,0.157,0.192,1);
  B.CustomColorFocused:=Vector4(0.15,0.23,0.28,1);
  B.CustomColorPressed:=Vector4(0.13,0.30,0.34,1);
  B.CustomColorDisabled:=Vector4(0.085,0.105,0.12,1);
  B.CustomTextColorUse:=True;B.CustomTextColor:=MenuText;
  B.TintDisabled:=Vector4(0.55,0.60,0.65,1);
  B.PaddingHorizontal:=16;B.PaddingVertical:=10;B.Border.AllSides:=0;
end;

procedure TMenuButton.SetStyle(const Value:TMenuButtonStyle);
begin
  FStyle:=Value;StyleMenuButton(Self);
  case Value of
    mbPrimary:begin
      CustomColorNormal:=MenuAccent;CustomColorFocused:=Vector4(0.46,0.92,0.97,1);
      CustomColorPressed:=Vector4(0.25,0.72,0.79,1);CustomTextColor:=MenuBackground;
    end;
    mbDanger:begin
      CustomColorNormal:=Vector4(0.25,0.14,0.16,1);CustomColorFocused:=Vector4(0.36,0.18,0.20,1);
      CustomColorPressed:=Vector4(0.43,0.19,0.21,1);CustomTextColor:=Vector4(1,0.72,0.73,1);
    end;
    mbGhost:begin
      CustomColorNormal:=Vector4(0,0,0,0);CustomColorFocused:=Vector4(0.12,0.19,0.23,1);
      CustomColorPressed:=Vector4(0.13,0.30,0.34,1);CustomTextColor:=MenuMuted;
    end;
  end;
end;

procedure StyleMenuButtons(const Root: TCastleUserInterface);
var I: Integer;
begin
  if Root is TCastleButton then StyleMenuButton(TCastleButton(Root));
  for I := 0 to Root.ControlsCount - 1 do StyleMenuButtons(Root.Controls[I]);
end;

procedure SelectMenuButton(const B:TCastleButton;const Selected:Boolean);
begin
  if B=nil then Exit;
  if B is TMenuButton then TMenuButton(B).Style:=mbGhost else StyleMenuButton(B);
  B.Toggle:=True;B.Pressed:=Selected;
  if Selected then B.CustomTextColor:=MenuAccent;
end;

function MenuEllipsis(const Text: String; const Font: TCastleAbstractFont;
  const PixelWidth: Single): String;
var S: UnicodeString;
begin
  Result := Text;
  if (Font = nil) or (PixelWidth <= 0) or (Font.TextWidth(Text) <= PixelWidth) then Exit;
  S := UTF8Decode(Text);
  repeat
    SetLength(S, Max(0, Length(S)-1));
    Result := UTF8Encode(S) + '…';
  until (S = '') or (Font.TextWidth(Result) <= PixelWidth);
end;

constructor TMenuFlow.Create(AOwner: TComponent);
begin
  inherited;
  FSpacing := 8;
  WidthFraction := 1;
  Height := 44;
end;

function MenuSummary(const Text: String; const Font: TCastleAbstractFont;
  const PixelWidth: Single; const MaxLines: Integer): String;
var Lines: TStringList; I: Integer;
begin
  Result := Text;
  if (Font = nil) or (PixelWidth <= 0) or (MaxLines < 1) then Exit;
  Lines := TStringList.Create;
  try
    Font.BreakLines(Text, Lines, PixelWidth);
    if Lines.Count > MaxLines then
    begin
      while Lines.Count > MaxLines do Lines.Delete(Lines.Count-1);
      Lines[MaxLines-1] := MenuEllipsis(TrimRight(Lines[MaxLines-1]) + '…', Font,
        PixelWidth);
    end;
    Result := '';
    for I := 0 to Lines.Count-1 do
    begin
      if I > 0 then Result := Result + LineEnding;
      Result := Result + Lines[I];
    end;
  finally
    Lines.Free;
  end;
end;

procedure TMenuFlow.Arrange;
var I: Integer; X, Y, RowH, W, H, Available: Single; C: TCastleUserInterface;
begin
  if FArranging or (EffectiveWidth <= 0) then Exit;
  FArranging := True;
  try
    X := 0; Y := 0; RowH := 0; Available := EffectiveWidth;
    for I := 0 to ControlsCount-1 do
    begin
      C := Controls[I];
      if not C.Exists then Continue;
      W := C.EffectiveWidth; H := C.EffectiveHeight;
      if (X > 0) and (X + W > Available) then
      begin X := 0; Y := Y + RowH + FSpacing; RowH := 0; end;
      C.Anchor(hpLeft, X);
      C.Anchor(vpTop, -Y);
      X := X + W + FSpacing;
      RowH := Max(RowH, H);
    end;
    Height := Y + RowH;
  finally
    FArranging := False;
  end;
end;

procedure TMenuFlow.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited;
  Arrange;
end;

procedure TMenuButton.DoClick;
begin PlayMenuClick;inherited;end;

constructor TMenuButton.Create(AOwner: TComponent);
var EmptyImage:TRGBAlphaImage;
begin
  inherited;
  StyleMenuButton(Self);
  { Suppress the engine's square solid background. The button keeps its
    native caption, image, focus, input and accessibility behavior. }
  EmptyImage:=TRGBAlphaImage.Create(1,1);EmptyImage.Clear(Vector4Byte(0,0,0,0));
  CustomBackgroundNormal.Image:=EmptyImage;
  FAutoIcon := True;
  FLastCaption := #1;
end;

procedure TMenuButton.SyncIcon;
var S, IconName: String;
begin
  if FLastCaption = Caption then Exit;
  FLastCaption := Caption;
  if not FAutoIcon then Exit;
  if not Image.Empty then Exit; { caller supplied an image }
  if (Caption = '') or (Pos('←', Caption) > 0) or
    ((not AutoSize) and (Width < 110)) then Exit;
  S := UTF8Encode(WideLowerCase(UTF8Decode(BoundUiSource(Self))));
  IconName := '';
  if (Pos('сохран', S)>0) or (Pos('save', S)>0) or (Pos('примен', S)>0) then IconName := 'save'
  else if (Pos('назад', S)>0) or (Pos('back', S)>0) or (Pos('←', S)>0) then IconName := 'back'
  else if (Pos('удал', S)>0) or (Pos('delete', S)>0) or (Pos('очист', S)>0) then IconName := 'delete'
  else if (Pos('отмен', S)>0) or (Pos('закры', S)>0) or (Pos('cancel', S)>0) then IconName := 'close'
  else if (Pos('вый', S)>0) or (Pos('выход', S)>0) or (Pos('quit', S)>0) or (Pos('sign out', S)>0) then IconName := 'logout'
  else if (Pos('войти', S)>0) or (Pos('sign in', S)>0) or (Pos('login', S)>0) then IconName := 'login'
  else if (Pos('ехат', S)>0) or (Pos('start', S)>0) or (Pos('ride', S)>0) then IconName := 'ride'
  else if (Pos('отключ', S)>0) or (Pos('disconnect', S)>0) then IconName := 'disconnect'
  else if (Pos('подключ', S)>0) or (Pos('connect', S)>0) then IconName := 'connect'
  else if (Pos('scan', S)>0) or (Pos('скан', S)>0) or (Pos('найти', S)>0) or (Pos('поиск', S)>0) or (Pos('search', S)>0) then IconName := 'search'
  else if (Pos('созда', S)>0) or (Pos('create', S)>0) then IconName := 'create'
  else if (Pos('добав', S)>0) or (Pos('import', S)>0) then IconName := 'import'
  else if (Pos('синх', S)>0) or (Pos('повтор', S)>0) or (Pos('обнов', S)>0) then IconName := 'refresh'
  else if (Pos('карт', S)>0) or (Pos('map', S)>0) or (Pos('глобус', S)>0) then IconName := 'library'
  else if (Pos('откры', S)>0) or (Pos('выбрать', S)>0) or (Pos('open', S)>0) or (Pos('pick', S)>0) then IconName := 'folder'
  else if (Pos('измен', S)>0) or (Pos('edit', S)>0) then IconName := 'edit'
  else if (Pos('подел', S)>0) or (Pos('сообщ', S)>0) then IconName := 'share'
  else if (Pos('любим', S)>0) then IconName := 'favorite'
  else if (Pos('ключ', S)>0) or (Pos('код', S)>0) then IconName := 'key';
  if IconName = '' then Exit;
  { A fixed-size selector must not grow or push its caption outside the cell. }
  if (not AutoSize) and (Font <> nil) and
    (Font.TextWidth(Caption) / Max(0.01, UIScale) + 54 > Width) then Exit;
  Image.Url := 'castle-data:/menu/icons/actions/' + IconName + '.png';
  ImageScale := 20 / 128;
  ImageMargin := 8;
end;

procedure TMenuButton.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  SyncIcon;
  inherited;
end;

procedure TMenuButton.Render;
var C,Edge,SavedText:TCastleColor;R:TFloatRectangle;Radius:Single;
begin
  R:=RenderRect;Radius:=Min(8*UIScale,Min(R.Width,R.Height)*0.25);
  if not Enabled then C:=CustomColorDisabled
  else if Pressed then C:=CustomColorPressed
  else if Focused then C:=CustomColorFocused else C:=CustomColorNormal;
  if C.W>0 then begin
    Edge:=MenuBorder;
    if(FStyle=mbPrimary)or(Caption='')then Edge:=C
    else if Focused or(Toggle and Pressed)then Edge:=Vector4(0.28,0.57,0.64,C.W);
    Edge.W:=C.W;
    DrawMenuPanel(R,Radius,Edge);
    DrawMenuPanel(R.Grow(-Max(1,UIScale)),Max(0,Radius-1),C);
  end;
  SavedText:=CustomTextColor;
  if not Enabled then CustomTextColor:=MenuMuted;
  try inherited;finally if not Enabled then CustomTextColor:=SavedText;end;
end;

initialization
  RegisterSerializableComponent(TMenuButton, 'Menu Button');
finalization
  FreeAndNil(FontOwner);
end.
