{ GameMenuTile — большая прямоугольная плашка пункта меню.

  Состав плашки (снизу вверх по слоям):
    1. Базовая заливка (FBaseColor)            — fallback-цвет, виден если нет картинки/видео
    2. Фон  (FBackground, TCastleImageControl) — картинка ИЛИ цикличное видео
    3. Затемнение (FOverlay)                   — тёмный полупрозрачный слой, чтобы текст читался
    4. Акцентная полоса (FAccent)              — яркая вертикальная полоса у левого края
    5. Иконка (FIcon)                          — слева, по вертикали по центру
    6. Подпись (FTitleLabel)                   — название пункта меню, по центру рядом с иконкой
    7. Кнопка-перехватчик (FButton)            — прозрачная во весь размер, ловит клики
                                                 и подсвечивает плашку при наведении

  Раскладка содержимого адаптивная: SetTileSize пересчитывает размер
  иконки, отступы и масштаб шрифта пропорционально высоте плашки.

  Использование:
    Tile := TMenuTile.Create(Owner);
    Tile.SetTitle('Устройства');
    Tile.SetIconUrl('castle-data:/icons/devices.png');
    Tile.SetBackgroundUrl('castle-data:/menu/devices_bg.png');     // или .mp4 — CGE сам поймёт
    Tile.SetBaseColor(Vector4(0.10, 0.29, 0.37, 1.0));             // запасной цвет
    Tile.OnTileClick := @ClickDevices;
    Parent.InsertFront(Tile); }
unit GameMenuTile;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses Classes, SysUtils, Math, CastleUIControls, CastleControls, CastleVectors, CastleColors, CastleURIUtils, GameMenuTheme;

type
  { Базовый класс встроенных страниц (вкладок) главного меню — области
    справа от колонки плашек. Это НЕ TCastleView: Start/Stop/FreeAtStop
    у страницы нет; меню зовёт PageShown/PageHidden при показе и
    сворачивании вкладки, а Update/Press страница получает от
    контейнера только пока Exists=True. }
  TMenuEmbeddedPage = class(TCastleUserInterface)
  public
    procedure PageShown; virtual;
    procedure PageHidden; virtual;
    function HandleBack: Boolean; virtual;
  end;

  TMenuEmbeddedPageClass = class of TMenuEmbeddedPage;

  TMenuTile = class(TCastleUserInterface)
  private
    FBaseColor:   TCastleRectangleControl;
    FBackground:  TCastleImageControl;
    FOverlay:     TCastleRectangleControl;
    FAccent:      TCastleRectangleControl;
    FIcon:        TCastleImageControl;
    FGlyph:TMenuGlyph;
    FTitleLabel:  TCastleLabel;
    FButton:      TCastleButton;

    FOnTileClick: TNotifyEvent;
    FSelected:    Boolean;
    FContentScale:Single;

    procedure InternalClick(Sender: TObject);
    procedure SetSelected(AValue: Boolean);
    { Пересчитать размер иконки, отступы и масштаб шрифта под текущие
      Width/Height плашки. Вызывается из SetTileSize. }
    procedure LayoutContent;
  public
    constructor Create(AOwner: TComponent); override;

    { Основные сеттеры }
    procedure SetTitle(const ATitle: String);
    procedure SetIconUrl(const AUrl: String);
    procedure SetBackgroundUrl(const AUrl: String);
    procedure SetBaseColor(const AColor: TCastleColor);
    procedure SetTileSize(AWidth, AHeight: Single; AScale:Single=0);
    procedure SetOverlayAlpha(AAlpha: Single);
    procedure SetIconSize(ASize: Single);
    procedure SetTitleFontScale(AScale: Single);

    { Прямой доступ для тонкой настройки }
    property BaseColorControl: TCastleRectangleControl read FBaseColor;
    property Background:       TCastleImageControl    read FBackground;
    property Overlay:          TCastleRectangleControl read FOverlay;
    property Icon:             TCastleImageControl    read FIcon;
    property TitleLabel:       TCastleLabel           read FTitleLabel;

    { Признак "выбранной" плашки. На True — золотая рамка по периметру.
      По умолчанию False — рамки нет, существующие плашки в основном меню
      этого изменения не замечают. }
    property Selected: Boolean read FSelected write SetSelected;

    property OnTileClick: TNotifyEvent read FOnTileClick write FOnTileClick;
  end;

implementation


uses UiTranslations,
  DebugLog;

procedure TMenuEmbeddedPage.PageShown;
begin
  { Базовая реализация пустая — наследники переопределяют. }
end;

procedure TMenuEmbeddedPage.PageHidden;
begin
  { Базовая реализация пустая — наследники переопределяют. }
end;

function TMenuEmbeddedPage.HandleBack: Boolean;
begin Result:=False; end;

const
  DEFAULT_TILE_WIDTH  = 360;
  DEFAULT_TILE_HEIGHT = 200;
  DEFAULT_ICON_SIZE   = 96;
  ACCENT_WIDTH        = 5;

constructor TMenuTile.Create(AOwner: TComponent);
begin
  inherited;

  AutoSizeToChildren := False;
  Width  := DEFAULT_TILE_WIDTH;
  Height := DEFAULT_TILE_HEIGHT;

  { 1. Базовая заливка — fallback-цвет под картинку. }
  FBaseColor := TMenuPanel.Create(Self);
  TMenuPanel(FBaseColor).Radius:=8;TCastleRectangleControl(FBaseColor).Color:=Vector4(0,0,0,0);
  TMenuPanel(FBaseColor).Stroke:=Vector4(0,0,0,0);
  FBaseColor.FullSize := True;
  FBaseColor.Color := Vector4(0,0,0,0);
  InsertFront(FBaseColor);

  { 2. Фон: картинка или видео. CGE TCastleImageControl умеет читать .png/.jpg
       и анимированные форматы (.gif, .avi, .ogv, .mp4 — зависит от сборки). }
  FBackground := TCastleImageControl.Create(Self);
  FBackground.FullSize := True;
  FBackground.Stretch := True;
  FBackground.ProportionalScaling := psEnclose;
  FBackground.Exists := False; { включится при назначении Url }
  InsertFront(FBackground);

  { 3. Затемнение для контраста текста. Альфа умеренная — после
       того как FBaseColor стал полупрозрачным, не хочется ещё сверху
       глушить картинку, иначе плашка превращается в кашу. }
  FOverlay := TCastleRectangleControl.Create(Self);
  FOverlay.FullSize := True;
  FOverlay.Color := Vector4(0,0,0,0);
  InsertFront(FOverlay);

  { 4. Акцентная полоса у левого края — цвет задаётся в SetBaseColor
       (осветлённый вариант базового). }
  FAccent := TCastleRectangleControl.Create(Self);
  FAccent.FullSize := False;
  FAccent.HeightFraction := 0.48;
  FAccent.Width := 3;
  FAccent.Exists:=False;
  FAccent.Color:=MenuAccent;
  FAccent.Anchor(hpLeft, 0);
  FAccent.Anchor(vpMiddle, 0);
  InsertFront(FAccent);

  { 5. Иконка слева, по вертикали по центру. Размер и отступы
       пересчитывает LayoutContent из SetTileSize. }
  FIcon := TCastleImageControl.Create(Self);
  FIcon.Width  := DEFAULT_ICON_SIZE;
  FIcon.Height := DEFAULT_ICON_SIZE;
  FIcon.Stretch := True;
  FIcon.ProportionalScaling := psEnclose;
  FIcon.Anchor(hpLeft, 18);
  FIcon.Anchor(vpMiddle, 0);
  FIcon.Exists := False; { включится при назначении Url }
  InsertFront(FIcon);

  { 6. Название пункта меню — по центру, правее иконки. }
  FGlyph:=TMenuGlyph.Create(Self);FGlyph.Exists:=False;InsertFront(FGlyph);
  FTitleLabel := TMenuLabel.Create(Self);
  FTitleLabel.Anchor(hpLeft, 20);
  FTitleLabel.Anchor(vpMiddle, 0);
  FTitleLabel.FontScale := 1.7;
  FTitleLabel.Color := MenuMuted;
  FTitleLabel.OutlineColor := Vector4(0, 0, 0, 0.85);
  FTitleLabel.Outline := 0;
  FTitleLabel.Caption := '';
  InsertFront(FTitleLabel);

  { 7. Прозрачная кнопка во весь размер — ловит клики и даёт hover-эффект.
       CustomBackground=True заставляет CGE рисовать наши CustomColor*,
       а не тему оформления. Альфа 0 в Normal — плашка полностью прозрачная,
       пока на ней нет курсора. }
  FButton := TMenuButton.Create(Self);
  FButton.FullSize := True;
  FButton.Caption := '';
  FButton.AutoSize := False;
  FButton.CustomBackground := True;
  FButton.CustomColorNormal  := Vector4(1, 1, 1, 0.00);
  FButton.CustomColorFocused := Vector4(0.55, 0.85, 0.95, 0.055);
  FButton.CustomColorPressed := Vector4(0.55, 0.85, 0.95, 0.10);
  FButton.OnClick := @InternalClick;
  InsertFront(FButton);

  { Тонкая светлая рамка всегда — «стеклянный» край плашки. При Selected
    заменяется на толстую золотую (SetSelected). }
  Border.AllSides := 0;
  BorderColor := Vector4(1.0, 1.0, 1.0, 0.15);

  FSelected := False;
  LayoutContent;
end;

procedure TMenuTile.InternalClick(Sender: TObject);
begin
  if Assigned(FOnTileClick) then
    FOnTileClick(Self);
end;

procedure TMenuTile.SetTitle(const ATitle: String);
begin
  BindUiText(FTitleLabel, ATitle);
end;

procedure TMenuTile.SetIconUrl(const AUrl: String);
begin
  if Pos('native:',AUrl)=1 then begin
    FGlyph.Exists:=True;FIcon.Exists:=False;
    if AUrl='native:home'then FGlyph.Kind:=mgHome
    else if AUrl='native:world'then FGlyph.Kind:=mgWorld
    else if AUrl='native:mountain'then FGlyph.Kind:=mgMountain
    else if AUrl='native:bicycle'then FGlyph.Kind:=mgBicycle
    else if AUrl='native:history'then FGlyph.Kind:=mgHistory
    else if AUrl='native:settings'then FGlyph.Kind:=mgSettings
    else FGlyph.Kind:=mgTraining;
    Exit;
  end;
  FGlyph.Exists:=False;

  if AUrl = '' then
  begin
    FIcon.Exists := False;
    Exit;
  end;

  { Пропускаем загрузку только если URIExists ТОЧНО говорит "нет такого
    файла". Если ответ ueUnknown (например, когда CGE ещё не понял схему)
    — пускаем дальше, пусть try/except разбирается. Так мы не отвергнем
    файл из-за ложного отрицательного ответа на проверку существования. }
  if URIExists(AUrl) = ueNotExists then
  begin
    Logger.Info('[MenuTile] ' + 'Иконка не найдена, пропуск: ' + AUrl);
    FIcon.Exists := False;
    Exit;
  end;

  try
    FIcon.Url := AUrl;
    FIcon.Exists := True;
    Logger.Info('[MenuTile] ' + 'Иконка загружена: ' + AUrl);
  except
    on E: Exception do
    begin
      Logger.Warning('[MenuTile] ' + 'Не удалось загрузить иконку ' + AUrl + ': ' + E.Message);
      FIcon.Url := '';
      FIcon.Exists := False;
    end;
  end;
end;

procedure TMenuTile.SetBackgroundUrl(const AUrl: String);
begin
  if AUrl = '' then
  begin
    FBackground.Exists := False;
    Exit;
  end;

  if URIExists(AUrl) = ueNotExists then
  begin
    Logger.Info('[MenuTile] ' + 'Фон не найден, пропуск: ' + AUrl);
    FBackground.Exists := False;
    Exit;
  end;

  try
    FBackground.Url := AUrl;
    FBackground.Exists := True;
    Logger.Info('[MenuTile] ' + 'Фон загружен: ' + AUrl);
  except
    on E: Exception do
    begin
      Logger.Warning('[MenuTile] ' + 'Не удалось загрузить фон ' + AUrl + ': ' + E.Message);
      FBackground.Url := '';
      FBackground.Exists := False;
    end;
  end;
end;

procedure TMenuTile.SetBaseColor(const AColor:TCastleColor);
begin
  FBaseColor.Color:=Vector4(0,0,0,0);FAccent.Color:=MenuAccent;
end;

procedure TMenuTile.SetTileSize(AWidth, AHeight: Single; AScale:Single);
begin
  FContentScale:=AScale;
  Width  := AWidth;
  Height := AHeight;
  LayoutContent;
end;

procedure TMenuTile.LayoutContent;
var S:Single;
begin
  S:=Max(0.65,Min(1,UIScale));
  if FContentScale>0 then S:=FContentScale;
  FIcon.Width:=22/S;FIcon.Height:=22/S;FIcon.Anchor(hpLeft,16/S);FIcon.Anchor(vpMiddle);
  FGlyph.Width:=22/S;FGlyph.Height:=22/S;FGlyph.Anchor(hpLeft,16/S);FGlyph.Anchor(vpMiddle);
  FTitleLabel.Anchor(hpLeft,52/S);FTitleLabel.Anchor(vpMiddle);
  FTitleLabel.FontSize:=15/S;FTitleLabel.FontScale:=1;
end;

procedure TMenuTile.SetOverlayAlpha(AAlpha: Single);
begin
  FOverlay.Color := Vector4(0, 0, 0, AAlpha);
end;

procedure TMenuTile.SetIconSize(ASize: Single);
begin
  FIcon.Width  := ASize;
  FIcon.Height := ASize;
end;

procedure TMenuTile.SetTitleFontScale(AScale:Single);
var Available,TextWidth:Single;
begin
  FTitleLabel.FontScale:=AScale;
  Available:=Width-(ACCENT_WIDTH+Height*0.14)*2-Height*0.62;
  if FTitleLabel.Font<>nil then begin
    TextWidth:=FTitleLabel.Font.TextWidth(FTitleLabel.Caption)/Max(0.01,UIScale);
    if(TextWidth>Available)and(Available>0)then FTitleLabel.FontScale:=AScale*Available/TextWidth;
  end;
end;

procedure TMenuTile.SetSelected(AValue:Boolean);
begin
  FSelected:=AValue;Border.AllSides:=0;FAccent.Exists:=AValue;
  if AValue then begin
    FBaseColor.Color:=Vector4(0.08,0.18,0.21,1);FTitleLabel.Color:=MenuText;
    FGlyph.Color:=MenuAccent;FIcon.Color:=MenuAccent;
  end else begin
    FBaseColor.Color:=Vector4(0,0,0,0);FTitleLabel.Color:=MenuMuted;
    FGlyph.Color:=MenuMuted;FIcon.Color:=MenuMuted;
  end;
end;

end.
