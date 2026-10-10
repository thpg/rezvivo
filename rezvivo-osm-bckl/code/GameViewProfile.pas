{ GameViewProfile — вкладка «Профиль» главного меню.

  Встроенная страница (TMenuEmbeddedPage): показывается в правой части
  меню рядом с колонкой плашек, а не полноэкранным вью. Кнопка
  ← Назад возвращает на вкладку «Маршруты». Дизайн бывшего
  полноэкранного вью встраивается целиком (TCastleDesign FullSize).

  Верхние вкладки: «Основное» (аккаунт, язык, графика), «Подключения»
  (внешние сервисы), «Параметры райдера» (вес, FTP, пол).
  Формы остаются живыми при переключении вкладок. }
unit GameViewProfile;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses GameMenuTheme,
  Classes, SysUtils, SyncObjs,
  CastleComponentSerialize, CastleUIControls, CastleControls,
  CastleVectors, CastleColors,
  GameGraphicsUI, GameCacheUI, GameAudioUI,GameInputUI,
  VeloSiteAPI,
  GameMenuTile, GameViewConnectors, GameTrainingZonesUI;

type
  TProfileTab = (ptMain, ptConnections, ptRider, ptSettings);
  TProfileAsyncAction = (paaIdle, paaPatch, paaLogout, paaRefresh, paaImportZones);
  TProfileAsyncState  = (pasIdle, pasRunning, pasSucceeded, pasFailed);

  TProfilePatchData = record
    Nickname: String;
    Weight:   Single;
    FtpW:     Integer;
    ZonesJSON: String;
  end;

  TProfileThread = class(TThread)
  private
    FAction:       TProfileAsyncAction;
    FPatch:        TProfilePatchData;
    FLock:         TCriticalSection;
    FState:        TProfileAsyncState;
    FErrorMessage: String;
    FAccountToken:QWord;
  protected
    procedure Execute; override;
  public
    property State:  TProfileAsyncState  read FState;
    property Action: TProfileAsyncAction read FAction;

    constructor Create(AAction: TProfileAsyncAction);
    destructor  Destroy; override;
    procedure Start;reintroduce;

    procedure SetPatchData(const APatch: TProfilePatchData);
    function  TakeError: String;
  end;

  TProfilePage = class(TMenuEmbeddedPage)
  private
    FDesign:       TCastleDesign;
    FLabelTitle:   TCastleLabel;
    FPageHeading:TCastleLabel;
    FTabFlow:TMenuFlow;
    FButtonBack:   TCastleButton;
    FSettingsHost: TCastleUserInterface;
    FSettingsScroll: TCastleScrollView;
    FTabTiles: array[TProfileTab] of TMenuTile;
    FActiveTab: TProfileTab;
    FAutoSaveDelay: Single;
    FProfileDirty: Boolean;
    procedure ProfileEdited(Sender:TObject);
  private
    FMainContainer, FRiderContainer, FPreferencesContainer: TCastleVerticalGroup;
    FRiderSection: TCastleUserInterface;
    FConnectionsPage: TConnectorsPage;
    FAccountOwner: TComponent;
    { Владелец всего динамического UI страницы: у страницы нет
      FreeAtStop, поэтому контент создаётся с owner=FContentOwner и
      освобождается явно при перестроении (BuildAll) и в PageHidden. }
    FContentOwner: TComponent;

    FGraphics: TGraphicsPanel;
    FGraphicsPreview:TGraphicsPreview;
    FAudio: TAudioPanel;
    FInput:TInputPanel;
    FDiskCache: TDiskCachePanel;

    { Language picker — dropdown: одна основная кнопка показывает текущий
      выбор; клик открывает FLangPopupOverlay (затемнение на всю
      страницу), внутри центрированная карта со списком языков. }
    FLangHint:TCastleLabel;
    FLangSectionLabel:    TCastleLabel;       { 'Interface language:' }
    FLangCurrentButton:   TCastleButton;      { показывает текущий выбор, клик = открыть popup }
    FLangPopupOverlay:    TCastleButton;      { на всю страницу, click = закрыть popup }
    FLangAutoButton:      TCastleButton;      { 'Auto' — внутри popup }
    FLangButtons:         array of TCastleButton; { по языку — внутри popup }

    FGenderSectionLabel: TCastleLabel;
    FBtnGenderMale:      TCastleButton;
    FBtnGenderFemale:    TCastleButton;

    FProfileSection:  TCastleUserInterface;
    FLabelStatus:     TCastleLabel;
    FLabelPlan:       TCastleLabel;
    FEditNickname:    TCastleEdit;
    FEditWeight:      TCastleEdit;
    FEditFtp:         TCastleEdit;
    FButtonSave:      TCastleButton;
    FButtonLogout:    TCastleButton;
    FButtonGotoLogin: TCastleButton;
    FLabelHint:       TCastleLabel;
    FLabelRiderHint:  TCastleLabel;
    FButtonRiderSave: TCastleButton;
    FButtonImportZones: TCastleButton;
    FZonesEditor: TTrainingZonesEditor;
    FZonesExpanded:Boolean;
    FZonesToggle:TCastleButton;
    procedure ToggleZones(Sender:TObject);
  private
    FImportNickname, FImportWeight: String;
    FInitialNickname, FInitialWeight, FInitialFtp: String;

    FBackground: TProfileThread;

    procedure ClickBack(Sender: TObject);
    procedure ClickTab(Sender: TObject);
    procedure SelectTab(ATab: TProfileTab);

    procedure ClickLangCurrent(Sender: TObject);   { открыть popup }
    procedure ClickLangBg(Sender: TObject);        { закрыть popup (клик по затемнению) }
    procedure ClickLangCardEater(Sender: TObject); { поглощает клик в области карты вне кнопок }
    procedure ClickLanguage(Sender: TObject);      { выбор языка — закрывает popup }

    procedure ClickGender(Sender: TObject);
    procedure BuildGenderUI;
    procedure UpdateGenderButtons;

    procedure ClickSave(Sender: TObject);
    procedure ClickImportZones(Sender: TObject);
    procedure ClickLogout(Sender: TObject);
    procedure ClickGotoLogin(Sender: TObject);
    procedure ClickEvents(Sender: TObject);

    procedure BuildAll;
    procedure BuildVeloSiteSection;
    procedure BuildQualityUI;
    procedure BuildLanguageUI;             { создаёт UI в Section }
    procedure BuildLangPopup;              { создаёт overlay+card на каждый BuildAll }
    procedure UpdateLangCurrentButton;     { обновляет caption главной кнопки }
    procedure UpdateLanguageButtons;       { подсветка выбранного в popup-списке }
    procedure RefreshFromCache;
    procedure SetHint(const AText: String; AIsError: Boolean);
    procedure HandleAsyncCompletion;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy;override;
    procedure ShowConnections;
    procedure ShowAccount;
    procedure ShowRider;
    procedure ShowSettings;
    function HandleBack: Boolean; override;
    function KeyboardRoot:TCastleUserInterface;
    procedure PageShown; override;
    procedure PageHidden; override;
    procedure Resize; override;
    procedure Update(const SecondsPassed: Single;
      var HandleInput: Boolean); override;
  end;

var
  ViewProfile: TProfilePage;

implementation

uses UiTranslations, Math,
  CastleLog,
  GameViewMenu, GameViewLogin,
  AppSettings, GameLocalization, GameUserData,GameRouteLibraryData,GameAccountChange;

function LanguageMenuName(const Index: Integer): String;
begin
  { The bundled UI font covers Latin and Cyrillic. Keep other choices
    readable instead of drawing a row of missing-glyph question marks. }
  case SupportedLanguages[Index].Code of
    'ja': Result := 'Japanese';
    'ko': Result := 'Korean';
    'zh-Hans': Result := 'Chinese (Simplified)';
    'zh-Hant': Result := 'Chinese (Traditional)';
    'ar': Result := 'Arabic';
  else
    Result := SupportedLanguages[Index].NativeName;
  end;
end;

{ ══════════════════════════════════════════════════════════════════
  TProfileThread
  ══════════════════════════════════════════════════════════════════ }

constructor TProfileThread.Create(AAction: TProfileAsyncAction);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FAction := AAction;
  FLock := TCriticalSection.Create;
  FState := pasIdle;
end;

destructor TProfileThread.Destroy;
begin
  if not Suspended then WaitFor;
  EndAccountChange(FAccountToken);
  FLock.Free;
  inherited;
end;

procedure TProfileThread.SetPatchData(const APatch: TProfilePatchData);
begin
  FPatch := APatch;
end;

procedure TProfileThread.Start;
begin
  try
    if FAction=paaLogout then FAccountToken:=BeginAccountChange;
    inherited Start;
    if Suspended then raise EThread.Create('Could not start account request');
  except on E:Exception do begin
    EndAccountChange(FAccountToken);FAccountToken:=0;
    FErrorMessage:=E.Message;FState:=pasFailed;
  end;end;
end;

procedure TProfileThread.Execute;
begin
  try
  FLock.Enter;
  try FState := pasRunning;
  finally FLock.Leave; end;

  try
    case FAction of
      paaPatch:
        begin
          VeloSite.PatchProfile(FPatch.Nickname, FPatch.Weight, FPatch.FtpW, FPatch.ZonesJSON);
          VeloSite.RefreshProfile;
        end;
      paaImportZones:
        begin
          VeloSite.ImportTrainingZones;
          VeloSite.RefreshProfile;
        end;
      paaLogout:
        VeloSite.Logout;
      paaRefresh:
        VeloSite.RefreshProfile;
    end;
    FLock.Enter;
    try FState := pasSucceeded;
    finally FLock.Leave; end;
  except
    on E: Exception do
    begin
      FLock.Enter;
      try
        FErrorMessage := E.Message;
        FState := pasFailed;
      finally FLock.Leave; end;
    end;
  end;
  finally EndAccountChange(FAccountToken);FAccountToken:=0;end;
end;

function TProfileThread.TakeError: String;
begin
  FLock.Enter;
  try Result := FErrorMessage;
  finally FLock.Leave; end;
end;

{ ══════════════════════════════════════════════════════════════════
  TProfilePage
  ══════════════════════════════════════════════════════════════════ }

constructor TProfilePage.Create(AOwner: TComponent);
var
  Row: TMenuFlow;
  Tab: TProfileTab;
  Background: TCastleRectangleControl;
const
  Captions: array[TProfileTab] of String =
    ('Account', 'Connections', 'Rider settings', 'Settings');
  Names: array[TProfileTab] of String =
    ('ProfileTabMain', 'ProfileTabConnections', 'ProfileTabRider', 'ProfileTabSettings');
  Icons: array[TProfileTab] of String = ('profile', 'devices', 'bikefit', 'profile');
  Widths: array[TProfileTab] of Single = (180, 210, 270, 240);
  Colors: array[TProfileTab] of TCastleColor =
    ((X:0.56; Y:0.52; Z:0.78; W:0.85),
     (X:0.30; Y:0.58; Z:0.68; W:0.85),
     (X:0.38; Y:0.62; Z:0.44; W:0.85),
     (X:0.36; Y:0.52; Z:0.64; W:0.85));
begin
  inherited;
  FullSize := True;
  Background := TCastleRectangleControl.Create(Self);
  Background.FullSize := True;
  Background.Color := MenuBackground;
  InsertBack(Background);

  { Дизайн бывшего полноэкранного вью встраиваем целиком. }
  FDesign := TCastleDesign.Create(Self);
  FDesign.FullSize := True;
  FDesign.Border.Top := 84;
  FDesign.Url := 'castle-data:/gameviewprofile.castle-user-interface';
  LocalizeDesignedUi(FDesign);
  TCastleRectangleControl(FDesign.DesignedComponent('Background')).Color:=MenuBackground;
  InsertFront(FDesign);

  FLabelTitle   := FDesign.DesignedComponent('LabelTitle') as TCastleLabel;
  FButtonBack   := FDesign.DesignedComponent('ButtonBack') as TCastleButton;
  FSettingsHost := FDesign.DesignedComponent('SettingsHost') as TCastleUserInterface;
  FSettingsHost.Parent.RemoveControl(FSettingsHost);
  FSettingsScroll := TMenuScrollView.Create(Self);
  FSettingsScroll.FullSize := True;
  FSettingsScroll.Border.Left := 20;
  FSettingsScroll.Border.Right := 20;
  FSettingsScroll.Border.Bottom := 12;
  FDesign.InsertFront(FSettingsScroll);
  FSettingsScroll.ScrollArea.InsertFront(FSettingsHost);
  FSettingsHost.Anchor(hpLeft);

  if Assigned(FLabelTitle) then
    FLabelTitle.Exists := False;
  if Assigned(FButtonBack) then
    FButtonBack.Exists := False;

  FPageHeading:=TMenuLabel.Create(Self);FPageHeading.CustomFont:=MenuFont(True);
  BindUiText(FPageHeading,'Settings');FPageHeading.FontSize:=30;FPageHeading.Anchor(hpLeft,24);FPageHeading.Anchor(vpTop,-16);
  FPageHeading.Exists:=False;InsertFront(FPageHeading);
  Row := TMenuFlow.Create(Self);FTabFlow:=Row;
  Row.Spacing := 10;
  Row.Anchor(hpLeft, 20);
  Row.Anchor(vpTop, -10);
  InsertFront(Row);
  for Tab := Low(TProfileTab) to High(TProfileTab) do
  begin
    FTabTiles[Tab] := TMenuTile.Create(Self);
    FTabTiles[Tab].Name := Names[Tab];
    FTabTiles[Tab].SetTileSize(Widths[Tab], 52);
    FTabTiles[Tab].SetTitle(Captions[Tab]);
    FTabTiles[Tab].SetTitleFontScale(1.0);
    FTabTiles[Tab].SetBaseColor(Colors[Tab]);
    FTabTiles[Tab].SetIconUrl('castle-data:/menu/icons/' + Icons[Tab] + '.png');
    FTabTiles[Tab].Tag := Ord(Tab);
    FTabTiles[Tab].OnTileClick := @ClickTab;
    Row.InsertFront(FTabTiles[Tab]);
  end;
end;

procedure TProfilePage.ShowRider;
begin SelectTab(ptRider);end;

procedure TProfilePage.Resize;
var S:Single;
begin
  inherited;
  S:=Max(0.65,Min(1,UIScale));
  if FPageHeading<>nil then begin
    FPageHeading.FontSize:=30/S;FPageHeading.Anchor(hpLeft,24/S);FPageHeading.Anchor(vpTop,-16/S);
  end;
end;

procedure TProfilePage.ShowAccount;
begin SelectTab(ptMain); end;

destructor TProfilePage.Destroy;
begin
  DetachBackgroundThread(FBackground);FBackground:=nil;
  inherited;
end;

procedure TProfilePage.ShowSettings;
begin SelectTab(ptSettings); end;

function TProfilePage.KeyboardRoot:TCastleUserInterface;
begin
  Result:=nil;
  if Assigned(FLangPopupOverlay)and FLangPopupOverlay.Exists then Result:=FLangPopupOverlay;
end;
function TProfilePage.HandleBack: Boolean;
begin
  Result := Assigned(FLangPopupOverlay) and FLangPopupOverlay.Exists;
  if Result then FLangPopupOverlay.Exists := False;
end;

procedure TProfilePage.ClickTab(Sender: TObject);
begin
  SelectTab(TProfileTab((Sender as TMenuTile).Tag));
end;

procedure TProfilePage.ShowConnections;
begin
  SelectTab(ptConnections);
end;

procedure TProfilePage.SelectTab(ATab: TProfileTab);
var Tab: TProfileTab;
begin
  if Assigned(FLangPopupOverlay) then FLangPopupOverlay.Exists := False;
  if Assigned(FConnectionsPage) and FConnectionsPage.Exists and
     (ATab <> ptConnections) then
  begin
    FConnectionsPage.PageHidden;
    FConnectionsPage.Exists := False;
  end;
  FActiveTab := ATab;
  if (ATab = ptSettings) and (FGraphics <> nil) then FGraphics.Refresh;
  if FDiskCache <> nil then FDiskCache.SetActive(ATab = ptSettings);
  if FGraphicsPreview<>nil then begin
    FGraphicsPreview.Exists:=ATab=ptSettings;
    if ATab<>ptSettings then FGraphicsPreview.ReleaseScene;
  end;
  FSettingsScroll.Border.Right:=20;FSettingsScroll.Border.Top:=0;
  FPageHeading.Exists:=ATab=ptSettings;FTabFlow.Exists:=ATab<>ptSettings;
  FPageHeading.FontSize:=30/Max(0.65,Min(1,UIScale));
  FDesign.Exists := ATab <> ptConnections;
  if Assigned(FMainContainer) then FMainContainer.Exists := ATab = ptMain;
  if Assigned(FRiderContainer) then FRiderContainer.Exists := ATab = ptRider;
  if Assigned(FPreferencesContainer) then FPreferencesContainer.Exists := ATab = ptSettings;
  if(FSettingsHost<>nil)and(FSettingsScroll<>nil)then begin
    case ATab of
      ptMain:FSettingsHost.Height:=370;
      ptSettings:FSettingsHost.Height:=Max(380,FPreferencesContainer.EffectiveHeight);
    else FSettingsHost.Height:=850;
    end;
    FSettingsScroll.ScrollArea.Height:=FSettingsHost.Height+16;
  end;
  if ATab = ptConnections then
  begin
    if FConnectionsPage = nil then
    begin
      FConnectionsPage := TConnectorsPage.Create(Self);
      FConnectionsPage.Name := 'ProfileConnections';
      FConnectionsPage.Border.Top := 84;
      FConnectionsPage.Exists := False;
      InsertFront(FConnectionsPage);
    end;
    if not FConnectionsPage.Exists then
    begin
      FConnectionsPage.Exists := True;
      FConnectionsPage.PageShown;
    end;
  end;
  for Tab := Low(TProfileTab) to High(TProfileTab) do begin
    FTabTiles[Tab].Selected := Tab = ATab;
    FTabTiles[Tab].Exists := (Tab = ptSettings) = (ATab = ptSettings);
  end;
end;

procedure TProfilePage.PageShown;
begin
  { Может вызываться повторно (вкладку свернули и открыли снова) —
    как и бывший Start: весь динамический UI перестраивается BuildAll
    заново (через пересоздание FContentOwner). }
  if Assigned(FLabelTitle) then FLabelTitle.Exists := False;
  if Assigned(FButtonBack) then FButtonBack.Exists := False;


  FActiveTab := ptMain;
  if FContentOwner=nil then BuildAll else HandleAsyncCompletion;

  if VeloSite.IsAuthorized and not Assigned(FBackground) then
  begin
    SetHint(T('Loading profile...'), False);
    FBackground := TProfileThread.Create(paaRefresh);
    FBackground.Start;
  end;
end;

procedure TProfilePage.PageHidden;
begin
  if FDiskCache <> nil then FDiskCache.SetActive(False);
  if FGraphicsPreview<>nil then begin FGraphicsPreview.Exists:=False;FGraphicsPreview.ReleaseScene end;
  if FProfileDirty then ClickSave(nil);
  if Assigned(FConnectionsPage) and FConnectionsPage.Exists then
  begin
    FConnectionsPage.PageHidden;
    FConnectionsPage.Exists := False;
  end;
  { A network request owns no UI. Keep it until completion / next PageShown
    so leaving the profile never waits for a slow server. }

end;

procedure TProfilePage.ClickBack(Sender: TObject);
begin
  ViewMenu.ShowRoutesPage;
end;

procedure TProfilePage.BuildAll;
begin
  if not Assigned(FSettingsHost) then Exit;

  { Идемпотентность: BuildAll зовётся из каждого PageShown и из
    ClickLanguage. ClearControls только отцепляет контролы (НЕ
    освобождает их), поэтому сначала отцепляем, потом сносим владельца
    FContentOwner — он освобождает весь динамический UI транзитивно. }
  if Assigned(FLangPopupOverlay) then
    RemoveControl(FLangPopupOverlay);
  FLangPopupOverlay := nil;
  FLangAutoButton   := nil;
  SetLength(FLangButtons, 0);
  FSettingsHost.ClearControls;
  FreeAndNil(FContentOwner);
  FAccountOwner := nil;
  FContentOwner := TComponent.Create(Self);

  { Обнуляем ссылки на уничтоженный контент — все они переназначаются
    ниже при перестроении секций. }
  FProfileSection    := nil;
  FLabelStatus       := nil;
  FLabelPlan         := nil;
  FEditNickname      := nil;
  FEditWeight        := nil;
  FEditFtp           := nil;
  FButtonSave        := nil;
  FButtonLogout      := nil;
  FButtonGotoLogin   := nil;
  FLabelHint         := nil;
  FLabelRiderHint    := nil;
  FButtonRiderSave   := nil;
  FLangSectionLabel  := nil;FLangHint:=nil;
  FLangCurrentButton := nil;
  FGenderSectionLabel := nil;
  FBtnGenderMale     := nil;
  FBtnGenderFemale   := nil;
  FGraphics := nil;FGraphicsPreview:=nil;
  FAudio := nil;
  FInput := nil;
  FDiskCache := nil;

  { Контейнер покрывает все секции основной вкладки, чтобы нижние
    кнопки графики оставались внутри области обработки кликов. }
  FSettingsHost.Height := 850;
  FSettingsScroll.ScrollArea.Height := 866;
  FSettingsHost.VerticalAnchorParent := vpTop;
  FSettingsHost.VerticalAnchorSelf := vpTop;
  FSettingsHost.Translation := Vector2(0, -8);

  FMainContainer := TCastleVerticalGroup.Create(FContentOwner);
  FMainContainer.Name := 'ProfileMainContent';
  FMainContainer.Spacing := 28;
  FMainContainer.Anchor(hpLeft, 0);
  FMainContainer.Anchor(vpTop, 0);
  FSettingsHost.InsertFront(FMainContainer);
  FRiderContainer := TCastleVerticalGroup.Create(FContentOwner);
  FRiderContainer.Name := 'ProfileRiderContent';
  FRiderContainer.Spacing := 28;
  FRiderContainer.Anchor(hpLeft, 0);
  FRiderContainer.Anchor(vpTop, 0);
  FSettingsHost.InsertFront(FRiderContainer);
  FPreferencesContainer := TCastleVerticalGroup.Create(FContentOwner);
  FPreferencesContainer.Name := 'MenuPreferences';
  FPreferencesContainer.Spacing := 28;
  FPreferencesContainer.Anchor(hpLeft, 0);
  FPreferencesContainer.Anchor(vpTop, 0);
  FSettingsHost.InsertFront(FPreferencesContainer);

  FProfileSection := TCastleUserInterface.Create(FContentOwner);
  FProfileSection.Width := FSettingsHost.EffectiveWidth;
  FProfileSection.Height := 284;
  FMainContainer.InsertFront(FProfileSection);
  FRiderSection := TCastleUserInterface.Create(FContentOwner);
  FRiderSection.Width := FSettingsHost.EffectiveWidth;
  FRiderSection.Height := 660;
  FRiderContainer.InsertFront(FRiderSection);
  BuildVeloSiteSection;

  BuildGenderUI;
  BuildLanguageUI;
  FAudio := TAudioPanel.Create(FContentOwner);
  FAudio.Width := FSettingsHost.EffectiveWidth;
  FPreferencesContainer.InsertFront(FAudio);
  FInput:=TInputPanel.Create(FContentOwner);
  FInput.Width:=FSettingsHost.EffectiveWidth;FPreferencesContainer.InsertFront(FInput);
  FDiskCache := TDiskCachePanel.Create(FContentOwner);
  FDiskCache.Width := FSettingsHost.EffectiveWidth;
  FPreferencesContainer.InsertFront(FDiskCache);
  BuildQualityUI;
  SelectTab(FActiveTab);
end;

procedure TProfilePage.BuildVeloSiteSection;
var
  Title, LabelN, LabelW, LabelF: TCastleLabel;
  P: TVeloSiteProfile;
  E: TVeloSiteEntitlements;
  RowButtons: TCastleHorizontalGroup;
  EventsButton:TMenuButton;
begin
  FProfileSection.ClearControls;
  FRiderSection.ClearControls;
  FreeAndNil(FAccountOwner);
  FAccountOwner := TComponent.Create(FContentOwner);
  FLabelStatus := nil; FLabelPlan := nil;
  FEditNickname := nil; FEditWeight := nil; FEditFtp := nil;
  FButtonSave := nil; FButtonRiderSave := nil;
  FButtonLogout := nil; FButtonGotoLogin := nil;
  FLabelHint := nil; FLabelRiderHint := nil;
  FZonesEditor := nil; FButtonImportZones := nil;

  Title := TMenuLabel.Create(FAccountOwner);
  BindUiText(Title, 'Account');
  Title.FontScale := 1.4;
  Title.Color := Vector4(1, 1, 1, 1);
  Title.Anchor(hpLeft, 0);
  Title.Anchor(vpTop, -4);
  FProfileSection.InsertFront(Title);

  Title := TMenuLabel.Create(FAccountOwner);
  BindUiText(Title, 'Rider settings');
  Title.FontScale := 1.4;
  Title.Color := White;
  Title.Anchor(hpLeft, 0);
  Title.Anchor(vpTop, -4);
  FRiderSection.InsertFront(Title);

  P := EffectiveRiderProfile;
  E := VeloSite.CachedEntitlements;

  FLabelStatus := TMenuLabel.Create(FAccountOwner);
  FLabelStatus.FontScale := 1.0;
  FLabelStatus.Color := Vector4(0.7, 0.95, 0.75, 1);
  if not VeloSite.IsAuthorized then
    BindUiText(FLabelStatus, 'Local profile — no account required')
  else if P.Email <> '' then
    FLabelStatus.Caption := T('Signed in as ') + P.Email
  else
    BindUiText(FLabelStatus, 'Signed in (profile not loaded yet)');
  FLabelStatus.Anchor(hpLeft, 0);
  FLabelStatus.Anchor(vpTop, -50);
  FProfileSection.InsertFront(FLabelStatus);

  FLabelPlan := TMenuLabel.Create(FAccountOwner);
  FLabelPlan.FontScale := 0.95;
  if E.HasAccess then
  begin
    if E.Source <> '' then
      FLabelPlan.Caption := T('Subscription active (') + E.Source + ')'
    else
      BindUiText(FLabelPlan, 'Subscription active');
  end
  else
    BindUiText(FLabelPlan, 'Free plan');
  FLabelPlan.Color := Vector4(0.7, 0.85, 1.0, 1);
  FLabelPlan.Anchor(hpLeft, 0);
  FLabelPlan.Anchor(vpTop, -78);
  FProfileSection.InsertFront(FLabelPlan);

  LabelN := TMenuLabel.Create(FAccountOwner);
  BindUiText(LabelN, 'Nickname:');
  LabelN.FontScale := 1.0;
  LabelN.Color := Vector4(0.85, 0.85, 0.9, 1);
  LabelN.Anchor(hpLeft, 0);
  LabelN.Anchor(vpTop, -126);
  FProfileSection.InsertFront(LabelN);

  FEditNickname := TMenuEdit.Create(FAccountOwner);
  FEditNickname.Name := 'ProfileNickname';
  FEditNickname.Width := 360;
  FEditNickname.Text := P.Nickname;
  FEditNickname.OnChange:=@ProfileEdited;
  FEditNickname.Anchor(hpLeft, 140);
  FEditNickname.Anchor(vpTop, -126);
  FProfileSection.InsertFront(FEditNickname);

  LabelW := TMenuLabel.Create(FAccountOwner);
  BindUiText(LabelW, 'Weight (kg):');
  LabelW.FontScale := 1.0;
  LabelW.Color := Vector4(0.85, 0.85, 0.9, 1);
  LabelW.Anchor(hpLeft, 0);
  LabelW.Anchor(vpTop, -64);
  FRiderSection.InsertFront(LabelW);

  FEditWeight := TMenuEdit.Create(FAccountOwner);
  FEditWeight.Name := 'ProfileWeight';
  FEditWeight.Width := 100;
  if P.WeightKg > 0 then
    FEditWeight.Text := FormatFloat('0.0', P.WeightKg)
  else
    FEditWeight.Text := '';
  FEditWeight.Anchor(hpLeft, 140);
  FEditWeight.Anchor(vpTop, -64);
  FRiderSection.InsertFront(FEditWeight);

  LabelF := TMenuLabel.Create(FAccountOwner);
  BindUiText(LabelF, 'FTP (W):');
  LabelF.FontScale := 1.0;
  LabelF.Color := Vector4(0.85, 0.85, 0.9, 1);
  LabelF.Anchor(hpLeft, 0);
  LabelF.Anchor(vpTop, -114);
  FRiderSection.InsertFront(LabelF);

  FEditFtp := TMenuEdit.Create(FAccountOwner);
  FEditFtp.Name := 'ProfileFtp';
  FEditFtp.Width := 100;
  if P.FtpW > 0 then
    FEditFtp.Text := IntToStr(P.FtpW)
  else
    FEditFtp.Text := '';
  FEditFtp.Anchor(hpLeft, 140);
  FEditFtp.Anchor(vpTop, -114);
  FRiderSection.InsertFront(FEditFtp);
  FInitialNickname := FEditNickname.Text;
  FInitialWeight := FEditWeight.Text;
  FInitialFtp := FEditFtp.Text;
  FEditFtp.OnChange:=@ProfileEdited;FEditWeight.OnChange:=@ProfileEdited;
  FProfileDirty:=False;

  RowButtons := TCastleHorizontalGroup.Create(FAccountOwner);
  RowButtons.Spacing := 12;
  RowButtons.Anchor(hpLeft, 0);
  RowButtons.Anchor(vpTop, -186);
  FProfileSection.InsertFront(RowButtons);

  FButtonSave := TMenuButton.Create(FAccountOwner);
  BindUiText(FButtonSave, 'Save');
  FButtonSave.MinWidth := 200;
  FButtonSave.PaddingHorizontal := 20;
  FButtonSave.PaddingVertical := 10;
  FButtonSave.OnClick := @ClickSave;
  RowButtons.InsertFront(FButtonSave);

  FButtonLogout := TMenuButton.Create(FAccountOwner);
  BindUiText(FButtonLogout, 'Sign out of account');
  FButtonLogout.MinWidth := 160;
  FButtonLogout.PaddingHorizontal := 20;
  FButtonLogout.PaddingVertical := 10;
  FButtonLogout.OnClick := @ClickLogout;
  RowButtons.InsertFront(FButtonLogout);
  FButtonLogout.Exists:=VeloSite.IsAuthorized;
  if not VeloSite.IsAuthorized then begin
    FButtonGotoLogin:=TMenuButton.Create(FAccountOwner);
    BindUiText(FButtonGotoLogin,'Sign in to sync');FButtonGotoLogin.OnClick:=@ClickGotoLogin;
    FButtonGotoLogin.Name:='ProfileSignIn';RowButtons.InsertFront(FButtonGotoLogin);
  end;

  EventsButton:=TMenuButton.Create(FAccountOwner);BindUiText(EventsButton,'Events');
  EventsButton.OnClick:=@ClickEvents;EventsButton.Name:='AccountEvents';
  EventsButton.Anchor(hpLeft,0);EventsButton.Anchor(vpTop,-274);FProfileSection.InsertFront(EventsButton);

  FLabelHint := TMenuLabel.Create(FAccountOwner);
  FLabelHint.Caption := '';
  FLabelHint.FontScale := 0.95;
  FLabelHint.Color := Vector4(0.6, 0.95, 0.7, 1);
  FLabelHint.Anchor(hpLeft, 0);
  FLabelHint.Anchor(vpTop, -240);
  FProfileSection.InsertFront(FLabelHint);

  RowButtons := TCastleHorizontalGroup.Create(FAccountOwner);
  RowButtons.Anchor(hpLeft, 0);
  FZonesEditor := TTrainingZonesEditor.Create(FAccountOwner);
  FZonesEditor.Name := 'ProfileTrainingZones';
  FZonesEditor.Anchor(hpLeft,0);
  FZonesEditor.Anchor(vpTop,-174);
  FRiderSection.InsertFront(FZonesEditor);
  FZonesEditor.Load(P.TrainingZonesJSON,FEditFtp);FZonesEditor.OnEdited:=@ProfileEdited;
  FZonesToggle:=TMenuButton.Create(FAccountOwner);FZonesToggle.Name:='ProfileZones';
  BindUiText(FZonesToggle,'Training zones (optional)');FZonesToggle.OnClick:=@ToggleZones;
  FZonesToggle.Anchor(hpLeft,0);FZonesToggle.Anchor(vpTop,-174);FRiderSection.InsertFront(FZonesToggle);
  FZonesEditor.Anchor(vpTop,-230);FZonesEditor.Exists:=FZonesExpanded;

  RowButtons.Spacing := 12;
  RowButtons.Anchor(vpTop, -550);
  FRiderSection.InsertFront(RowButtons);
  FButtonRiderSave := TMenuButton.Create(FAccountOwner);
  FButtonRiderSave.Name := 'ProfileSaveRider';
  BindUiText(FButtonRiderSave, 'Save');
  FButtonRiderSave.MinWidth := 200;
  FButtonRiderSave.PaddingHorizontal := 20;
  FButtonRiderSave.PaddingVertical := 10;
  FButtonRiderSave.OnClick := @ClickSave;
  RowButtons.InsertFront(FButtonRiderSave);
  FButtonImportZones := TMenuButton.Create(FAccountOwner);
  FButtonImportZones.Name := 'ProfileImportZones';
  BindUiText(FButtonImportZones, 'Replace zones and FTP from Intervals.icu');
  FButtonImportZones.FontScale := 0.85;
  FButtonImportZones.PaddingHorizontal := 12;
  FButtonImportZones.PaddingVertical := 10;
  FButtonImportZones.OnClick := @ClickImportZones;
  RowButtons.InsertFront(FButtonImportZones);
  FButtonImportZones.Exists:=VeloSite.IsAuthorized;
  FLabelRiderHint := TMenuLabel.Create(FAccountOwner);
  FLabelRiderHint.FontScale := 0.8;
  FLabelRiderHint.MaxWidth := FSettingsHost.EffectiveWidth;
  BindUiText(FLabelRiderHint, 'Changes are saved automatically on this computer.');
  FLabelRiderHint.Color := White;
  FLabelRiderHint.Anchor(hpLeft, 0);
  FLabelRiderHint.Anchor(vpTop, -608);
  FRiderSection.InsertFront(FLabelRiderHint);
  ToggleZones(nil);
end;

procedure TProfilePage.SetHint(const AText: String; AIsError: Boolean);
  procedure ApplyTo(ALabel: TCastleLabel);
  begin
    if ALabel = nil then Exit;
    ALabel.Caption := AText;
    if AIsError then ALabel.Color := Vector4(1.0, 0.55, 0.45, 1)
    else ALabel.Color := Vector4(0.6, 0.95, 0.7, 1);
  end;
begin
  ApplyTo(FLabelHint);
  ApplyTo(FLabelRiderHint);
end;

procedure TProfilePage.ClickEvents(Sender:TObject);
begin ViewMenu.OpenTab('events');end;

procedure TProfilePage.ClickGotoLogin(Sender: TObject);
var Blocked:String;
begin
  Blocked:=ViewMenu.AccountChangeError;
  if Blocked<>''then begin SetHint(Blocked,True);Exit;end;
  { Логин остаётся полноэкранным вью; после успешного входа он сам
    возвращается на ViewMenu. }
  ViewMenu.OpenChildView(ViewLogin);
end;

procedure TProfilePage.ClickSave(Sender: TObject);
var
  Patch: TProfilePatchData;
  W: Single;
  FtpV: Integer;
  FS: TFormatSettings;
begin
  if not Assigned(FEditNickname) then Exit;

  Patch.Nickname := Trim(FEditNickname.Text);
  Patch.Weight := 0;
  Patch.FtpW := 0;
  Patch.ZonesJSON := '';
  if Assigned(FZonesEditor) then
    try
      Patch.ZonesJSON := FZonesEditor.ReadChanges;
    except
      on E: Exception do begin
        SelectTab(ptRider);
        SetHint(E.Message,True);
        Exit;
      end;
    end;

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if Trim(FEditWeight.Text) <> '' then
  begin
    if not TryStrToFloat(StringReplace(Trim(FEditWeight.Text), ',', '.', []),
      W, FS) then
    begin
      SelectTab(ptRider);
      SetHint(T('Weight: invalid number'), True);
      Exit;
    end;
    if (W < 30) or (W > 250) then
    begin
      SelectTab(ptRider);
      SetHint(T('Weight must be between 30 and 250 kg'), True);
      Exit;
    end;
    Patch.Weight := W;
  end;
  if Trim(FEditFtp.Text) <> '' then
  begin
    if not TryStrToInt(Trim(FEditFtp.Text), FtpV) then
    begin
      SelectTab(ptRider);
      SetHint(T('FTP must be an integer'), True);
      Exit;
    end;
    if (FtpV < 50) or (FtpV > 700) then
    begin
      SelectTab(ptRider);
      SetHint(T('FTP must be between 50 and 700 W'), True);
      Exit;
    end;
    Patch.FtpW := FtpV;
  end;

  try SaveLocalRider(Patch.Nickname,Patch.Weight,Patch.FtpW,Patch.ZonesJSON);
  except on E:Exception do begin SetHint(E.Message,True);Exit;end;end;
  FInitialNickname:=FEditNickname.Text;FInitialWeight:=FEditWeight.Text;FInitialFtp:=FEditFtp.Text;
  FProfileDirty:=Assigned(FBackground);
  SetHint(T('Saved locally'), False);
  if not VeloSite.IsAuthorized or Assigned(FBackground)then Exit;
  FButtonSave.Enabled := False;
  FButtonRiderSave.Enabled := False;
  FButtonImportZones.Enabled := False;
  FBackground := TProfileThread.Create(paaPatch);
  FBackground.SetPatchData(Patch);
  FBackground.Start;
end;

procedure TProfilePage.ClickImportZones(Sender: TObject);
begin
  if Assigned(FBackground) or not VeloSite.IsAuthorized then Exit;
  SetHint(UiText('Loading zones and FTP from Intervals.icu…'),False);
  FImportNickname := FEditNickname.Text;
  FImportWeight := FEditWeight.Text;
  FButtonSave.Enabled := False;
  FButtonRiderSave.Enabled := False;
  FButtonImportZones.Enabled := False;
  FBackground := TProfileThread.Create(paaImportZones);
  FBackground.Start;
end;

procedure TProfilePage.ClickLogout(Sender: TObject);
var Blocked:String;
begin
  Blocked:=ViewMenu.AccountChangeError;
  if Blocked<>''then begin SetHint(Blocked,True);Exit;end;
  if Assigned(FBackground) then Exit;
  SetHint(T('Signing out...'), False);
  FButtonLogout.Enabled := False;
  FBackground := TProfileThread.Create(paaLogout);
  FBackground.Start;
end;

procedure TProfilePage.RefreshFromCache;
begin
  BuildVeloSiteSection;
end;

procedure TProfilePage.HandleAsyncCompletion;
var
  Action: TProfileAsyncAction;
  Err: String;
begin
  if not Assigned(FBackground) then Exit;
  if FBackground.State in [pasIdle, pasRunning] then Exit;

  Action := FBackground.Action;

  if FBackground.State = pasFailed then
  begin
    Err := FBackground.TakeError;
    FreeAndNil(FBackground);
    case Action of
      paaPatch, paaImportZones:
        begin
          SetHint(T('Saved locally. Sync failed: ') + Err, True);
          if Assigned(FButtonSave) then FButtonSave.Enabled := True;
          if Assigned(FButtonRiderSave) then FButtonRiderSave.Enabled := True;
          if Assigned(FButtonImportZones) then FButtonImportZones.Enabled := True;
        end;
      paaLogout:
        begin
          SetHint(T('Sign out failed: ') + Err, True);
          if Assigned(FButtonLogout) then FButtonLogout.Enabled := True;
        end;
      paaRefresh:
        SetHint(T('Failed to refresh profile: ') + Err, True);
    end;
    Exit;
  end;

  FreeAndNil(FBackground);

  case Action of
    paaPatch, paaImportZones:
      begin
        if(Action=paaPatch)and FProfileDirty then Exit;
        if Action=paaImportZones then AcceptServerRider;
        RefreshFromCache;
        if Action=paaImportZones then begin
          FEditNickname.Text := FImportNickname;
          FEditWeight.Text := FImportWeight;
        end;
        SetHint(T('Saved'), False);
      end;
    paaLogout:
      begin
        SetHint(T('You have signed out.'), False);
        RefreshFromCache;
      end;
    paaRefresh:
      begin
        { Do not discard a draft typed while the current profile was loading. }
        if Assigned(FEditNickname) and
          ((FEditNickname.Text<>FInitialNickname) or (FEditWeight.Text<>FInitialWeight) or
           (FEditFtp.Text<>FInitialFtp)) then Exit;
        if Assigned(FZonesEditor) then
          try
            if FZonesEditor.ReadChanges<>'' then Exit;
          except Exit; end;
        RefreshFromCache;
      end;
  end;
end;

procedure TProfilePage.ProfileEdited(Sender:TObject);
begin FProfileDirty:=True;FAutoSaveDelay:=1.2;end;

procedure TProfilePage.Update(const SecondsPassed: Single;
  var HandleInput: Boolean);
var W,H,P:Single;
begin
  inherited;
  HandleAsyncCompletion;
  if (FActiveTab = ptSettings) and (FGraphics <> nil) then
  begin
    if (Container<>nil) and (Container.UnscaledHeight<690) then FDesign.Border.Top:=52
    else FDesign.Border.Top:=84;
    W:=FDesign.EffectiveWidthForChildren;H:=FDesign.EffectiveHeightForChildren;
    FGraphicsPreview.Exists:=True;
    if not FGraphicsPreview.Expanded then begin
      FGraphicsPreview.Width:=W-40;FGraphicsPreview.Height:=48;
      FGraphicsPreview.Anchor(hpRight,-20);FGraphicsPreview.Anchor(vpTop,-4);
      FSettingsScroll.Border.Right:=20;FSettingsScroll.Border.Top:=60;
    end else if (W>=1040) and (FDesign.RenderRect.Width>=950) then begin
      P:=Min(720,W*0.44);
      FGraphicsPreview.Width:=P;FGraphicsPreview.Height:=H-24;
      FGraphicsPreview.Anchor(hpRight,-20);FGraphicsPreview.Anchor(vpTop,-4);
      FSettingsScroll.Border.Right:=P+40;FSettingsScroll.Border.Top:=0;
    end else begin
      P:=Min(300,Max(190,H*0.37));
      FGraphicsPreview.Width:=W-40;FGraphicsPreview.Height:=P;
      FGraphicsPreview.Anchor(hpRight,-20);FGraphicsPreview.Anchor(vpTop,-4);
      FSettingsScroll.Border.Right:=20;FSettingsScroll.Border.Top:=P+20;
    end;
    FSettingsHost.Width:=Max(220,FSettingsScroll.EffectiveWidthForChildren-16);
    if FLangHint<>nil then begin
      FLangHint.MaxWidth:=FSettingsHost.EffectiveWidth;
      FLangHint.Parent.Width:=FSettingsHost.EffectiveWidth;
      FLangHint.Parent.Height:=Max(130,100+FLangHint.EffectiveHeight);
    end;
    FGraphics.Width := FSettingsHost.EffectiveWidth;
    FAudio.Width := FSettingsHost.EffectiveWidth;
    FInput.Width := FSettingsHost.EffectiveWidth;
    FDiskCache.Width := FSettingsHost.EffectiveWidth;
    FSettingsHost.Height := Max(380, FPreferencesContainer.EffectiveHeight);
    FSettingsScroll.ScrollArea.Height := FSettingsHost.Height + 16;
  end;
  if FProfileDirty then begin
    FAutoSaveDelay:=FAutoSaveDelay-SecondsPassed;
    if FAutoSaveDelay<=0 then begin FAutoSaveDelay:=2;ClickSave(nil);end;
  end;
  { Обновляем caption главной кнопки на каждом кадре. Это дешёво —
    UpdateLangCurrentButton сравнивает с текущим Caption и меняет только
    если что-то изменилось (например, watcher переключил применённый
    язык после прихода профиля VeloSite). }
  UpdateLangCurrentButton;
  UpdateGenderButtons;
end;

{ ── Texture quality ──────────────────────────────────────────────── }

{ ── Gender: male / female, локально как язык ── }

procedure TProfilePage.BuildGenderUI;
var
  Section: TCastleUserInterface;
  Title, Hint: TCastleLabel;
  Group: TCastleHorizontalGroup;
  VContainer: TCastleUserInterface;
begin
  Section := TCastleUserInterface.Create(FContentOwner);
  Section.Width := FSettingsHost.EffectiveWidth;
  Section.Height := 120;

  Title := TMenuLabel.Create(FContentOwner);
  BindUiText(Title, 'Gender');
  Title.FontScale := 1.4;
  Title.Color := Vector4(1, 1, 1, 1);
  Title.Anchor(hpLeft, 0);
  Title.Anchor(vpTop, -4);
  Section.InsertFront(Title);

  FGenderSectionLabel := TMenuLabel.Create(FContentOwner);
  BindUiText(FGenderSectionLabel, 'Rider:');
  FGenderSectionLabel.FontScale := 1.0;
  FGenderSectionLabel.Color := Vector4(0.85, 0.85, 0.9, 1);
  FGenderSectionLabel.Anchor(hpLeft, 0);
  FGenderSectionLabel.Anchor(vpTop, -50);
  Section.InsertFront(FGenderSectionLabel);

  Group := TCastleHorizontalGroup.Create(FContentOwner);
  Group.Spacing := 12;
  Group.Anchor(vpTop, -50);
  Group.Anchor(hpLeft, 240);
  Section.InsertFront(Group);

  FBtnGenderMale := TMenuButton.Create(FContentOwner);
  BindUiText(FBtnGenderMale, 'Male');
  FBtnGenderMale.MinWidth := 140;
  FBtnGenderMale.PaddingHorizontal := 16;
  FBtnGenderMale.PaddingVertical := 10;
  FBtnGenderMale.Tag := 0;
  FBtnGenderMale.OnClick := @ClickGender;
  Group.InsertFront(FBtnGenderMale);

  FBtnGenderFemale := TMenuButton.Create(FContentOwner);
  BindUiText(FBtnGenderFemale, 'Female');
  FBtnGenderFemale.MinWidth := 140;
  FBtnGenderFemale.PaddingHorizontal := 16;
  FBtnGenderFemale.PaddingVertical := 10;
  FBtnGenderFemale.Tag := 1;
  FBtnGenderFemale.OnClick := @ClickGender;
  Group.InsertFront(FBtnGenderFemale);

  Hint := TMenuLabel.Create(FContentOwner);
  BindUiText(Hint, 'Used for the rider model in Bike fit and races. Saved locally.');
  Hint.FontScale := 0.85;
  Hint.Color := Vector4(0.6, 0.6, 0.65, 1);
  Hint.Anchor(hpLeft, 0);
  Hint.Anchor(vpTop, -98);
  Section.InsertFront(Hint);

  VContainer := FRiderContainer;
  VContainer.InsertFront(Section);
  UpdateGenderButtons;
end;

procedure TProfilePage.ClickGender(Sender: TObject);
begin
  if (Sender as TCastleButton).Tag = 1 then
    Settings.SetGender('female')
  else
    Settings.SetGender('male');
  UpdateGenderButtons;
end;

procedure TProfilePage.UpdateGenderButtons;

  procedure StyleSelected(B: TCastleButton; Selected: Boolean);
  begin
    SelectMenuButton(B, Selected);
  end;

var
  Female: Boolean;
begin
  Female := SameText(Settings.GetGender, 'female');
  StyleSelected(FBtnGenderMale, not Female);
  StyleSelected(FBtnGenderFemale, Female);
end;

{ ── Language section: одна кнопка-открыватель в Section, popup в Self ── }

procedure TProfilePage.BuildLanguageUI;
var
  Section, VContainer: TCastleUserInterface;
  Title, Hint: TCastleLabel;
  Group: TCastleHorizontalGroup;
begin
  Section := TCastleUserInterface.Create(FContentOwner);
  Section.Width := FSettingsHost.EffectiveWidth;
  Section.Height := 130;

  Title := TMenuLabel.Create(FContentOwner);
  BindUiText(Title, 'Language');
  Title.FontScale := 1.4;
  Title.Color := Vector4(1, 1, 1, 1);
  Title.Anchor(hpLeft, 0);
  Title.Anchor(vpTop, -4);
  Section.InsertFront(Title);

  FLangSectionLabel := TMenuLabel.Create(FContentOwner);
  BindUiText(FLangSectionLabel, 'Interface language:');
  FLangSectionLabel.FontScale := 1.0;
  FLangSectionLabel.Color := Vector4(0.85, 0.85, 0.9, 1);
  FLangSectionLabel.Anchor(hpLeft, 0);
  FLangSectionLabel.Anchor(vpTop, -50);
  Section.InsertFront(FLangSectionLabel);

  { Кнопку оборачиваем в TCastleHorizontalGroup ровно так же, как
    BuildQualityUI (это единственный паттерн, который доказанно ловит
    клики в этой иерархии Section/VContainer/FSettingsHost — anchor'енные
    напрямую в Section кнопки клики не получают). }
  Group := TCastleHorizontalGroup.Create(FContentOwner);
  Group.Spacing := 0;
  Group.Anchor(vpTop, -50);
  Group.Anchor(hpLeft, 240);
  Section.InsertFront(Group);

  FLangCurrentButton := TMenuButton.Create(FContentOwner);
  BindUiText(FLangCurrentButton, 'English  v');      { v вместо ▼ — без UTF-8 warnings }
  FLangCurrentButton.MinWidth := 240;
  FLangCurrentButton.PaddingHorizontal := 16;
  FLangCurrentButton.PaddingVertical := 10;
  FLangCurrentButton.OnClick := @ClickLangCurrent;
  Group.InsertFront(FLangCurrentButton);

  Hint := TMenuLabel.Create(FContentOwner);
  FLangHint:=Hint;
  Hint.Caption := T('Auto = use language from your VeloSite profile.'
    + ' This choice is saved locally and does not change your VeloSite profile.');
  Hint.MaxWidth := FSettingsHost.EffectiveWidth;
  Hint.FontScale := 0.85;
  Hint.Color := Vector4(0.6, 0.6, 0.65, 1);
  Hint.Anchor(hpLeft, 0);
  Hint.Anchor(vpTop, -98);
  Section.InsertFront(Hint);

  VContainer := FPreferencesContainer;
  VContainer.InsertFront(Section);

  { Popup пересоздаётся каждым BuildAll (owner=FContentOwner): перед
    перестроением BuildAll отцепляет и обнуляет его, поэтому здесь он
    всегда nil. Ветка с Assigned оставлена на случай прямого вызова
    BuildLanguageUI в обход BuildAll. }
  if not Assigned(FLangPopupOverlay) then
    BuildLangPopup;

  UpdateLangCurrentButton;
end;

procedure TProfilePage.BuildLangPopup;
const
  CardWidth  = 320;
  CardHeight = 540;
var
  Card: TCastleButton;
  CardTitle: TCastleLabel;
  ListGroup: TCastleVerticalGroup;
  ListScroll: TCastleScrollView;
  Btn: TCastleButton;
  I: Integer;
begin
  { Overlay = TCastleButton на всю страницу с тёмным полупрозрачным
    фоном. Клик по нему = клик «вне карты» = закрыть. AutoSize=False
    обязателен, иначе FullSize игнорируется. Owner=FContentOwner —
    popup освобождается вместе с остальным динамическим UI при
    перестроении (BuildAll) и в PageHidden; перед освобождением он
    отцепляется от страницы RemoveControl'ом. }
  FLangPopupOverlay := TCastleButton.Create(FContentOwner);
  FLangPopupOverlay.CustomBackground := True;
  FLangPopupOverlay.FullSize := True;
  FLangPopupOverlay.AutoSize := False;
  FLangPopupOverlay.Caption := '';
  FLangPopupOverlay.PaddingHorizontal := 0;
  FLangPopupOverlay.PaddingVertical := 0;
  with FLangPopupOverlay.CustomColorNormalPersistent do
  begin
    Red := 0; Green := 0; Blue := 0; Alpha := 0.6;
  end;
  FLangPopupOverlay.CustomColorFocused := FLangPopupOverlay.CustomColorNormal;
  FLangPopupOverlay.CustomColorPressed := FLangPopupOverlay.CustomColorNormal;
  FLangPopupOverlay.OnClick := @ClickLangBg;
  FLangPopupOverlay.Exists := False;     { показывается только при клике }
  Self.InsertFront(FLangPopupOverlay);

  { Card — TCastleButton с пустым OnClick, поглощает клик в области карты
    вне списка кнопок (иначе клик прошёл бы в overlay и закрыл попап). }
  Card := TCastleButton.Create(FContentOwner);
  Card.CustomBackground := True;
  Card.AutoSize := False;
  Card.Width := CardWidth;
  Card.Height := CardHeight;
  Card.Caption := '';
  Card.PaddingHorizontal := 0;
  Card.PaddingVertical := 0;
  with Card.CustomColorNormalPersistent do
  begin
    Red := 0.12; Green := 0.12; Blue := 0.18; Alpha := 1.0;
  end;
  Card.CustomColorFocused := Card.CustomColorNormal;
  Card.CustomColorPressed := Card.CustomColorNormal;
  Card.OnClick := @ClickLangCardEater;
  Card.Anchor(hpMiddle);
  Card.Anchor(vpMiddle);
  FLangPopupOverlay.InsertFront(Card);

  CardTitle := TMenuLabel.Create(FContentOwner);
  BindUiText(CardTitle, 'Choose language');
  CardTitle.FontScale := 1.2;
  CardTitle.Color := Vector4(1, 1, 1, 1);
  CardTitle.Anchor(hpMiddle);
  CardTitle.Anchor(vpTop, -16);
  Card.InsertFront(CardTitle);

  ListScroll := TMenuScrollView.Create(FContentOwner);
  ListScroll.FullSize := True;
  ListScroll.Border.Left := 12;
  ListScroll.Border.Right := 12;
  ListScroll.Border.Top := 54;
  ListScroll.Border.Bottom := 12;
  Card.InsertFront(ListScroll);
  ListScroll.ScrollArea.AutoSizeToChildren := True;
  ListGroup := TCastleVerticalGroup.Create(FContentOwner);
  ListGroup.Spacing := 4;
  ListGroup.Anchor(hpLeft);
  ListGroup.Anchor(vpTop);
  ListScroll.ScrollArea.InsertFront(ListGroup);

  { Auto-кнопка первая в списке. Tag=-1 → SetUserLanguage(''). }
  FLangAutoButton := TMenuButton.Create(FContentOwner);
  BindUiText(FLangAutoButton, 'Auto');
  FLangAutoButton.MinWidth := CardWidth - 48;
  FLangAutoButton.PaddingHorizontal := 12;
  FLangAutoButton.PaddingVertical := 8;
  FLangAutoButton.Tag := -1;
  FLangAutoButton.OnClick := @ClickLanguage;
  ListGroup.InsertFront(FLangAutoButton);

  SetLength(FLangButtons, Length(SupportedLanguages));
  for I := Low(SupportedLanguages) to High(SupportedLanguages) do
  begin
    Btn := TMenuButton.Create(FContentOwner);
    Btn.Caption := LanguageMenuName(I);
    Btn.MinWidth := CardWidth - 48;
    Btn.PaddingHorizontal := 12;
    Btn.PaddingVertical := 8;
    Btn.Tag := I;
    Btn.OnClick := @ClickLanguage;
    ListGroup.InsertFront(Btn);
    FLangButtons[I] := Btn;
  end;
end;

procedure TProfilePage.ClickLangCurrent(Sender: TObject);
begin
  if not Assigned(FLangPopupOverlay) then Exit;
  UpdateLanguageButtons;     { обновить подсветку перед показом }
  FLangPopupOverlay.Exists := True;
end;

procedure TProfilePage.ClickLangBg(Sender: TObject);
begin
  if Assigned(FLangPopupOverlay) then
    FLangPopupOverlay.Exists := False;
end;

procedure TProfilePage.ClickLangCardEater(Sender: TObject);
begin
  { Намеренно пусто — поглощаем клик в области карты вне кнопок,
    чтобы он не дошёл до Overlay и не закрыл попап. }
end;

procedure TProfilePage.ClickLanguage(Sender: TObject);
var
  BtnTag: Integer;
begin
  BtnTag := (Sender as TCastleButton).Tag;
  if BtnTag = -1 then
    SetUserLanguage('')
  else
    SetUserLanguage(SupportedLanguages[BtnTag].Code);
  if Assigned(FLangPopupOverlay) then
    FLangPopupOverlay.Exists := False;
  { Bound captions update in place; preserve unsaved profile fields. }
  UpdateLangCurrentButton;
  UpdateLanguageButtons;
end;

procedure TProfilePage.UpdateLangCurrentButton;
var
  Local, Applied, NewCaption: String;
  I: Integer;
begin
  if not Assigned(FLangCurrentButton) then Exit;
  Local := Settings.GetLanguage;
  Applied := CurrentAppliedLanguage;
  if Local = '' then
    NewCaption := T('Auto') + ' (' + Applied + ')'
  else
  begin
    NewCaption := Local;     { fallback — код }
    for I := Low(SupportedLanguages) to High(SupportedLanguages) do
      if SupportedLanguages[I].Code = Local then
      begin
        NewCaption := LanguageMenuName(I);
        Break;
      end;
  end;
  { Маркер dropdown'а — обычная буква 'v' вместо ▼ чтобы избежать
    UTF-8 warnings 4104/4105 при компиляции под Windows. }
  NewCaption := NewCaption + '  v';
  if FLangCurrentButton.Caption <> NewCaption then
    FLangCurrentButton.Caption := NewCaption;
end;

procedure TProfilePage.UpdateLanguageButtons;

  procedure StyleSelected(B: TCastleButton; Selected: Boolean);
  begin
    SelectMenuButton(B, Selected);
  end;

var
  LocalLang, AppliedLang, SelectedCode: String;
  I: Integer;
  AutoActive: Boolean;
begin
  LocalLang   := Settings.GetLanguage;
  AppliedLang := CurrentAppliedLanguage;
  AutoActive  := (LocalLang = '');

  if AutoActive then
    SelectedCode := AppliedLang
  else
    SelectedCode := LocalLang;

  StyleSelected(FLangAutoButton, AutoActive);
  for I := Low(SupportedLanguages) to High(SupportedLanguages) do
    if I < Length(FLangButtons) then
      StyleSelected(FLangButtons[I], SupportedLanguages[I].Code = SelectedCode);
end;

procedure TProfilePage.BuildQualityUI;
begin
  FGraphicsPreview:=TGraphicsPreview.Create(FContentOwner);
  FGraphicsPreview.Exists:=False;FDesign.InsertFront(FGraphicsPreview);
  FGraphics := TGraphicsPanel.Create(FContentOwner);
  FGraphics.Preview:=FGraphicsPreview;
  FGraphics.Width := FSettingsHost.EffectiveWidth;
  FPreferencesContainer.InsertBack(FGraphics);
end;

procedure TProfilePage.ToggleZones(Sender:TObject);
var Y:Single;
begin
  if Sender<>nil then FZonesExpanded:=not FZonesExpanded;
  FZonesEditor.Exists:=FZonesExpanded;
  if FZonesExpanded then Y:=610 else Y:=230;
  FButtonRiderSave.Parent.Anchor(vpTop,-Y);FLabelRiderHint.Anchor(vpTop,-Y-58);
  FRiderSection.Height:=Y+110;
end;

end.
