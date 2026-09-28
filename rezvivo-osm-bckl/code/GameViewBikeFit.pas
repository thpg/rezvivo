{ GameViewBikeFit — вкладка «Байкфит»: параметры байка и 3D-превью.

  Раскладка:
    • Слева — параметры (байк, каденс, фит).
    • Справа — результат (bike+rider): педалирование + смена поз.

  Райдер берётся по полу из профиля: MEN.glb / FEM.glb
  (AppSettings.Gender → SelectedRiderGlb) → LoadActiveBikeInstance. }
unit GameViewBikeFit;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses GameMenuTheme, Osm3dRiderShadow,
  Classes, SysUtils, Math, fpjson,
  CastleComponentSerialize, CastleUIControls, CastleControls,
  CastleVectors, CastleColors, CastleURIUtils, CastleFilesUtils,
  CastleViewport, CastleScene, CastleCameras, CastleTransform,
  CastleProjection, CastleBoxes, CastleRenderOptions, X3DNodes,
  BikeParametric, RiderTripo, RiderPoseCatalog, BikeGeometryLib, GameBikeAvatar, GameMenuTile;

type
  TBikeFitPage = class(TMenuEmbeddedPage)
  private
    FDesign:      TCastleDesign;
    FLabelTitle:  TCastleLabel;
    FLabelStatus: TCastleLabel;
    FButtonBack:  TCastleButton;
    FButtonApply: TCastleButton;
    FMainHost:    TCastleUserInterface;

    { bottom halves }
    FBottomRow: TCastleUserInterface;
    FColParams, FColResult: TCastleRectangleControl;
    FSectionButtons:array[0..2]of TMenuButton;
    FSection:Integer;
    FBikeControls,FCadenceControls:TCastleUserInterface;
    FDyeTitle:TCastleLabel;
    FVpResult: TCastleViewport;
    FPreviewItems: TCastleRootTransform;
    FLiveRide, FLiveSettingsDirty: Boolean;
    FFitSaveDelay:Single;
    FValueButtons:array[0..9]of TCastleButton;
    FValueLabels:array[0..9]of TCastleLabel;
    FValueRow,FValueIndex:Integer;
    FValuePopup:TCastleRectangleControl;
    FValueEdit:TCastleEdit;
    procedure ClickValue(Sender:TObject);
    procedure ApplyValue(Sender:TObject);
    procedure CancelValue(Sender:TObject);
  private
    FPoseAuto:Boolean;
    FPosePrev,FPoseNext,FPoseToggle,FRiderParams:TCastleButton;
    procedure ClickPose(Sender:TObject);
    procedure ClickRiderParams(Sender:TObject);
  private
    FLastLiveCenter: TVector3;
    FCadenceCaption: TCastleLabel;

    FNavResult: TCastleExamineNavigation;
    FLblPose, FLblCadence, FLblResultInfo: TCastleLabel;
    FLblStack, FLblReach: TCastleLabel;
    FFitOverlay: TCastleRectangleControl;
    FBtnBikePick, FBtnSizePick: TCastleButton;
    FBtnCadenceDown, FBtnCadenceUp: TCastleButton;
    FBtnSeatHDown, FBtnSeatHUp: TCastleButton;
    FBtnSeatODown, FBtnSeatOUp: TCastleButton;
    FBtnSpacersDown, FBtnSpacersUp: TCastleButton;
    FBtnStemDown, FBtnStemUp: TCastleButton;
    FBtnHeightDown, FBtnHeightUp: TCastleButton;
    FBtnInseamDown, FBtnInseamUp: TCastleButton;
    FBtnBulkDown, FBtnBulkUp: TCastleButton;
    FBtnBellyDown, FBtnBellyUp: TCastleButton;
    FBtnKneeDown, FBtnKneeUp: TCastleButton;
    FBtnAnkleDown, FBtnAnkleUp: TCastleButton;
    FLblSeatH, FLblSeatO, FLblSpacers, FLblStem: TCastleLabel;
    FLblHeight, FLblInseam, FLblBulk, FLblBelly: TCastleLabel;
    FLblKnee, FLblAnkle: TCastleLabel;
    FPopupOverlay: TCastleButton;
    FPopupCard: TCastleButton;
    FPopupTitle: TCastleLabel;
    FBikeFilter: TCastleEdit;
    FPopupScroll: TCastleScrollView;
    FPopupList: TCastleVerticalGroup;
    FPopupKind: Integer; { 0 none, 1 bike, 2 size }

    FResultBike: TBikeInstance;
    FPrevKey, FPrevFill: TCastleDirectionalLight;  { свет вьюпорта результата }

    { ── color strip: оверлей слева на панели результата ──
      0..6 = TClothSlot (одежда/кожа/волосы), 7 = рама, 8 = ободы. }
    FDyeStrip: TCastleRectangleControl;
    FDyeBtns: array[0..9] of TCastleButton;
    FDyePop: TCastleRectangleControl;
    FDyePopSw: array[0..12] of TCastleButton;  { [0] = «выкл», 1..12 = палитра }
    FDyePopSlot: Integer;                      { -1 = закрыт }
    FDyeColor: array[TClothSlot] of TVector3;
    FDyeOn: array[TClothSlot] of Boolean;
    FBikeFrameC, FBikeRimC: TVector3;
    FBikeFrameOn, FBikeRimOn: Boolean;
    FHelmetC: TVector3;                        { tint-фактор шлема }
    FHelmetOn: Boolean;
    FOrigFrameC, FOrigRimC: TVector3;          { сток из bike json (для «выкл») }

    FBikePaths, FBikeNames: TStringList;
    FSizeNames: TStringList;
    FPoseNames: TStringList;
    FGeoList: TBikeGeometryList;
    FModelInfo: TBikeModelInfo;
    FSelBike, FSelSize, FSelPose: Integer;

    FCadenceRpm: Single;
    FFitSeatExt, FFitSaddleOff, FFitSpacers, FFitStem: Single;
    FFitHeightCm, FFitInseamCm, FFitBulk, FFitBelly: Single;
    FFitKneeFlare, FFitAnkleFlex: Single;
    FFitInited: Boolean;
    FSeededRestH: Single; { RestHeight last seeded from; 0=none, -1=keep settings }
    FPoseTimer: Single;
    FPoseCycleSec: Single;
    FPoseBlendSec: Single;
    FDirtyResult: Boolean;
    FLoadingPreview, FReleasePreviewPending: Boolean;
    FUiOwner: TComponent;
    FCachedBikeUrl: string;
    FCachedBikeJson: string;
    FGlbWorker: TTripoGlbWorker;
    FWantRiderPath: string;

    procedure ClickApply(Sender: TObject);
    procedure ClickSection(Sender:TObject);
    procedure LayoutSections;
    procedure ClickBikePick(Sender: TObject);
    procedure ClickSizePick(Sender: TObject);
    procedure ClickPopupBg(Sender: TObject);
    procedure ClickPopupCard(Sender: TObject);
    procedure ClickPopupBike(Sender: TObject);
    procedure ClickPopupSize(Sender: TObject);
    procedure BikeFilterChange(Sender: TObject);
    procedure ClickCadenceDown(Sender: TObject);
    procedure ClickCadenceUp(Sender: TObject);
    procedure ClickSeatHDown(Sender: TObject);
    procedure ClickSeatHUp(Sender: TObject);
    procedure ClickSeatODown(Sender: TObject);
    procedure ClickSeatOUp(Sender: TObject);
    procedure ClickSpacersDown(Sender: TObject);
    procedure ClickSpacersUp(Sender: TObject);
    procedure ClickStemDown(Sender: TObject);
    procedure ClickStemUp(Sender: TObject);
    procedure ClickHeightDown(Sender: TObject);
    procedure ClickHeightUp(Sender: TObject);
    procedure ClickInseamDown(Sender: TObject);
    procedure ClickInseamUp(Sender: TObject);
    procedure ClickBulkDown(Sender: TObject);
    procedure ClickBulkUp(Sender: TObject);
    procedure ClickBellyDown(Sender: TObject);
    procedure ClickBellyUp(Sender: TObject);
    procedure ClickKneeDown(Sender: TObject);
    procedure ClickKneeUp(Sender: TObject);
    procedure ClickAnkleDown(Sender: TObject);
    procedure ClickAnkleUp(Sender: TObject);
    procedure ApplyRiderShapeToPreview;
    procedure ApplyKneeAnkleToPreview;
    procedure SeedRiderShapeFromBike;
    procedure BuildLayout;
    function  MakeNavBtn(const Cap: string; AClick: TNotifyEvent;
      AWidth: Single = 44; AHeight: Single = 32): TCastleButton;
    function  MakeParamBlock(AParent: TCastleUserInterface; const ACaption: string;
      ATop: Single; out APrev, ANext: TCastleButton;
      out ALbl: TCastleLabel): TCastleUserInterface;
    function  MakeFitRow(AParent: TCastleUserInterface; const ACaption: string;
      ATop: Single; out APrev, ANext: TCastleButton;
      out ALbl: TCastleLabel): TCastleUserInterface;
    procedure SetupViewport(out AVp: TCastleViewport; out ANav: TCastleExamineNavigation;
      AHost: TCastleUserInterface);
    procedure FitCameraToItems(AVp: TCastleViewport);

    procedure ScanLibraries;
    function  CurrentRiderPath: string;
    function  CurrentRiderName: string;
    procedure ClosePopup;
    procedure OpenBikePopup;
    procedure OpenSizePopup;
    procedure FillBikePopupList;
    procedure FillSizePopupList;
    procedure LoadSelectedInsights;
    function  CurrentBikeCaption: string;
    function  CurrentSizeCaption: string;
    function  CurrentSizeName: string;
    procedure LoadPoseNames;

    function  EnsureBikeJson: Boolean;
    procedure ApplySelectedRiderOnly;
    procedure RequestResultRider(const APath: string);
    procedure PumpResultRiderLoad;
    procedure ReloadResultPreview;
    procedure ApplyResultPose;
    procedure AdvancePoseCycle;
    procedure ApplyCadenceToResult;
    procedure NudgeFit(var AValue: Single; ADelta, AMin, AMax: Single);
    procedure ApplyFitToPreview;
    procedure SyncFitFromBikeIfNeeded;
    procedure UpdateReachStackOverlay;
    procedure AttachLiveRide;
    procedure UpdateLiveCamera(const Reset: Boolean);
    procedure LiveFitChanged;
    procedure FreePreviewBikes;
    procedure UpdateLabels;
    procedure LanguageChanged(Sender: TObject);
    { ── color strip ── }
    procedure BuildColorStrip;
    procedure ClickDyeSlot(Sender: TObject);
    procedure ClickDyeSw(Sender: TObject);
    procedure CloseDyePopup;
    procedure FillDyePopup(AIdx: Integer);
    procedure UpdateDyeStripVisuals;
    procedure ApplyClothSlot(Slot: TClothSlot; const C: TVector3; AOn: Boolean);
    procedure ApplyHelmetColorLive(const C: TVector3; AOn: Boolean);
    procedure ReapplyHelmetColor;
    procedure ApplyRiderShaderDye;
    procedure ApplyBikeColorLive(AFrame: Boolean; const C: TVector3; AOn: Boolean);
    procedure ReapplyColorsAfterBuild;
    procedure SaveBikeFitColors;
    procedure LoadBikeFitColors;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure PageShown; override;
    procedure PageHidden; override;
    procedure Resize; override;
    function HandleBack:Boolean; override;
    procedure BeforeRender; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    { MCP: 0 = male (MEN.glb), 1 = female (FEM.glb). Reloads result. }
    procedure McpSelectRider(AIndex: Integer);
    { MCP: AParam = height|inseam|bulk|belly|knee|ankle|seat|offset|spacers|stem|cadence;
      ASteps signed, one UI click each. }
    procedure McpNudge(const AParam: string; ASteps: Integer);
    { MCP: цвет слота — jersey|shorts|socks|boots|gloves|skin|hair|frame|rim|
      helmet; AOn=False = «выкл» (сток). C — компоненты 0..1. }
    procedure McpSetColor(const ASlot: string; const C: TVector3; AOn: Boolean);
    procedure McpFillStatus(AResult: TJSONObject);
    { MCP: свет превью/результата (env = IBL-ambient райдера, key/fill =
      вьюпорт, rkey/rfill = свети сцены райдера). Не указанный аргумент
      не меняется; эхом возвращает все значения + diag светов. }
    procedure McpLighting(AParams: TJSONObject; AResult: TJSONObject);
    function RiderCount: Integer;
  end;

var
  ViewBikeFit: TBikeFitPage;

implementation

uses CastleApplicationProperties,UiTranslations,
  jsonparser, CastleKeysMouse,
  GameViewMenu, GameViewPlay, AppSettings, DebugLog;

const
  DefaultCamPos: TVector3 = (X: 1.6; Y: 0.95; Z: 2.1);
  DefaultCamDir: TVector3 = (X: -0.55; Y: -0.2; Z: -0.8);
  DefaultCamUp:  TVector3 = (X: 0; Y: 1; Z: 0);
  ParamsWidthFrac = 0.34;
  ResultWidthFrac = 0.66;
  ResultBarH     = 40;
  DefaultPoseCycleSec = 3.5;
  DefaultPoseBlendSec = 1.0;
  PopupNone = 0;
  PopupBike = 1;
  PopupSize = 2;
  BaseBikeUrl = 'castle-data:/bike_road.json';
  BikePopupMaxRows = 80;

type
  TBikeFitNavigation = class(TCastleExamineNavigation)
  public
    function Press(const Event: TInputPressRelease): Boolean; override;
  end;

function TBikeFitNavigation.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited;
  { CGE starts navigation dragging but returns False from Press. Consume the
    press here so a parent view (or the paused ride below the menu) cannot
    replace the pointer capture and receive subsequent motion instead. }
  if (Event.EventType = itMouseButton) and ReallyEnableMouseDragging and
     (MouseDraggingStarted = Event.FingerIndex) then
    Result := True;
end;

procedure AddPreviewLights(AOwner: TComponent; AItems: TCastleRootTransform;
  out AKey, AFill: TCastleDirectionalLight);
begin
  { Same two lights as avatareditor (softened: pure-IBL лук — окружение
    райдера RiderEnv даёт основной свет, ключ/филл лишь лёгкий намёк).
    CGE bakes every light into the compiled program; 8 dir + 1 point +
    TSkinNode + ClothDye was magenta. }
  AKey := TCastleDirectionalLight.Create(AOwner);
  AKey.Intensity := 0.6;
  AKey.Rotation := Vector4(1, 0.2, 0, -0.9);
  AItems.Add(AKey);
  AFill := TCastleDirectionalLight.Create(AOwner);
  AFill.Intensity := 0.4;
  AFill.Rotation := Vector4(0, 1, 0, 2.4);
  AItems.Add(AFill);
end;

{ ─── TBikeFitPage ─────────────────────────────────────────────────────────── }
constructor TBikeFitPage.Create(AOwner: TComponent);
begin
  inherited;
  FullSize := True;
  FSelBike := -1;
  FSelSize := -1;
  FSelPose := 0;
  FPopupKind := PopupNone;
  FCadenceRpm := 80;
  FFitSeatExt := 150;
  FFitSaddleOff := 0;
  FFitSpacers := 20;
  FFitStem := 100;
  FFitHeightCm := 0;
  FFitInseamCm := 0;
  FFitBulk := 0;
  FFitBelly := 0;
  FFitKneeFlare := 0;
  FFitAnkleFlex := 0;
  FFitInited := False;
  FSeededRestH := 0;
  FPoseTimer := 0;
  FPoseCycleSec := DefaultPoseCycleSec;
  FPoseBlendSec := DefaultPoseBlendSec;
  { цвета: дефолты как в редакторе; активность — из Settings (PageShown) }
  FDyePopSlot := -1;
  FDyeColor[csJersey] := Vector3(0.95, 0.45, 0.72);
  FDyeColor[csShorts] := Vector3(0.40, 0.75, 0.95);
  FDyeColor[csSocks]  := Vector3(0.96, 0.85, 0.15);
  FDyeColor[csBoots]  := Vector3(0.75, 0.52, 0.95);
  FDyeColor[csGloves] := Vector3(0.35, 0.82, 0.30);
  FDyeColor[csSkin]   := ClothDyeNativeColor(csSkin);
  FDyeColor[csHair]   := Vector3(0.09, 0.05, 0.025);
  FBikePaths := TStringList.Create;
  FBikeNames := TStringList.Create;
  FSizeNames := TStringList.Create;
  FPoseNames := TStringList.Create;
  FGeoList := nil;

  FDesign := TCastleDesign.Create(Self);
  FDesign.FullSize := True;
  FDesign.Url := 'castle-data:/gameviewbikefit.castle-user-interface';
  LocalizeDesignedUi(FDesign);
  InsertFront(FDesign);

  FLabelTitle  := FDesign.DesignedComponent('LabelTitle') as TCastleLabel;
  FLabelStatus := FDesign.DesignedComponent('LabelStatus') as TCastleLabel;
  FButtonBack  := FDesign.DesignedComponent('ButtonBack') as TCastleButton;
  FButtonApply := FDesign.DesignedComponent('ButtonApply') as TCastleButton;
  FMainHost    := FDesign.DesignedComponent('MainHost') as TCastleUserInterface;

  if FLabelTitle <> nil then
    FLabelTitle.Exists := False;
  if FButtonBack <> nil then
    FButtonBack.Exists := False;
  if FMainHost <> nil then
  begin
    FMainHost.Border.Top := 4;
    FMainHost.Border.Bottom := 52;
  end;
  FLabelStatus.Anchor(vpBottom, 72);
  FLabelStatus.FontSize := 14;

  FButtonApply.OnClick := @ClickApply;

  BuildLayout;
  ObserveUiLanguage(Self, @LanguageChanged);
end;

destructor TBikeFitPage.Destroy;
begin
  FWantRiderPath := '';
  if FGlbWorker <> nil then
  begin
    FGlbWorker.WaitFor;
    FreeAndNil(FGlbWorker);
  end;
  FreePreviewBikes;
  FreeAndNil(FBikePaths);
  FreeAndNil(FBikeNames);
  FreeAndNil(FSizeNames);
  FreeAndNil(FPoseNames);
  FreeAndNil(FGeoList);
  inherited;
end;

function TBikeFitPage.MakeNavBtn(const Cap: string; AClick: TNotifyEvent;
  AWidth, AHeight: Single): TCastleButton;
begin
  Result := TMenuButton.Create(FUiOwner);
  BindUiText(Result, Cap);
  Result.AutoSize := False;
  Result.Width := AWidth;
  Result.Height := AHeight;
  Result.FontScale := 1.1;
  Result.CustomBackground := True;
  Result.CustomColorNormal := Vector4(0.105,0.157,0.192,1);
  Result.CustomColorFocused := Vector4(0.15,0.23,0.28,1);
  Result.CustomColorPressed := Vector4(0.13,0.30,0.34,1);
  Result.OnClick := AClick;
end;

function TBikeFitPage.MakeParamBlock(AParent: TCastleUserInterface;
  const ACaption: string; ATop: Single;
  out APrev, ANext: TCastleButton; out ALbl: TCastleLabel): TCastleUserInterface;
var
  Cap: TCastleLabel;
  Row: TCastleUserInterface;
begin
  Result := TCastleRectangleControl.Create(FUiOwner);
  TCastleRectangleControl(Result).Color := MenuSurface;
  Result.WidthFraction := 1.0;
  Result.Height := 96;
  Result.Border.Left := 10;
  Result.Border.Right := 10;
  Result.Anchor(hpMiddle, 0);
  Result.Anchor(vpTop, ATop);
  AParent.InsertFront(Result);

  Cap := TMenuLabel.Create(FUiOwner);
  BindUiText(Cap, ACaption);
  if ACaption = UiText('Cadence (preview)') then FCadenceCaption := Cap;
  Cap.Color := MenuMuted;
  Cap.FontScale := 0.9;
  Cap.Anchor(hpLeft, 12);
  Cap.Anchor(vpTop, -10);
  Result.InsertFront(Cap);

  Row := TCastleUserInterface.Create(FUiOwner);
  Row.WidthFraction := 1.0;
  Row.Height := 40;
  Row.Border.Left := 8;
  Row.Border.Right := 8;
  Row.Anchor(hpMiddle, 0);
  Row.Anchor(vpBottom, 12);
  Result.InsertFront(Row);

  APrev := MakeNavBtn('◀', nil, 48, 36);
  APrev.Anchor(hpLeft, 0);
  APrev.Anchor(vpMiddle, 0);
  Row.InsertFront(APrev);

  ANext := MakeNavBtn('▶', nil, 48, 36);
  ANext.Anchor(hpRight, 0);
  ANext.Anchor(vpMiddle, 0);
  Row.InsertFront(ANext);

  ALbl := TMenuLabel.Create(FUiOwner);
  ALbl.Color := MenuText;
  ALbl.FontScale := 1.05;
  ALbl.Anchor(hpMiddle, 0);
  ALbl.Anchor(vpMiddle, 0);
  ALbl.MaxWidth := 220;
  Row.InsertFront(ALbl);
end;

function TBikeFitPage.MakeFitRow(AParent: TCastleUserInterface;
  const ACaption: string; ATop: Single;
  out APrev, ANext: TCastleButton; out ALbl: TCastleLabel): TCastleUserInterface;
var
  Cap: TCastleLabel;
begin
  Result := TCastleUserInterface.Create(FUiOwner);
  Result.WidthFraction := 1.0;
  Result.Height := 36;
  Result.Border.Left := 10;
  Result.Border.Right := 10;
  Result.Anchor(hpMiddle, 0);
  Result.Anchor(vpTop, ATop);
  AParent.InsertFront(Result);

  Cap := TMenuLabel.Create(FUiOwner);
  BindUiText(Cap, ACaption);
  Cap.Color := MenuMuted;
  Cap.FontScale := 0.8;
  Cap.Anchor(hpLeft, 4);
  Cap.Anchor(vpMiddle, 0);
  Result.InsertFront(Cap);

  ANext := MakeNavBtn('+', nil, 34, 28);
  ANext.FontScale := 0.95;
  ANext.Anchor(hpRight, 0);
  ANext.Anchor(vpMiddle, 0);
  Result.InsertFront(ANext);

  ALbl := TMenuLabel.Create(FUiOwner);
  ALbl.Color := MenuText;
  ALbl.FontScale := 0.9;
  ALbl.Anchor(hpRight, -40);
  ALbl.Anchor(vpMiddle, 0);
  Result.InsertFront(ALbl);

  APrev := MakeNavBtn('−', nil, 34, 28);
  APrev.FontScale := 0.95;
  APrev.Anchor(hpRight, -118);
  APrev.Anchor(vpMiddle, 0);
  Result.InsertFront(APrev);
  if FValueRow<=High(FValueButtons)then begin
    FValueLabels[FValueRow]:=ALbl;ALbl.Exists:=False;
    FValueButtons[FValueRow]:=MakeNavBtn('',@ClickValue,74,30);
    FValueButtons[FValueRow].Name:='FitValue'+IntToStr(FValueRow);
    FValueButtons[FValueRow].Tag:=FValueRow;
    FValueButtons[FValueRow].Anchor(hpRight,-38);FValueButtons[FValueRow].Anchor(vpMiddle);
    Result.InsertFront(FValueButtons[FValueRow]);Inc(FValueRow);
  end;
end;

procedure TBikeFitPage.SetupViewport(out AVp: TCastleViewport;
  out ANav: TCastleExamineNavigation; AHost: TCastleUserInterface);
var
  LKey, LFill, LDummyEnv1, LDummyRKey, LDummyRFill: Single;
begin
  AVp := TRiderShadowViewport.Create(FUiOwner);
  AVp.FullSize := True;
  AVp.Transparent := False;
  AVp.BackgroundColor := MenuSurface;
  AHost.InsertFront(AVp);

  ANav := TBikeFitNavigation.Create(AVp);
  AVp.InsertBack(ANav);

  AddPreviewLights(FUiOwner, AVp.Items, FPrevKey, FPrevFill);

  { key/fill из общего rider_lighting.json (пишет редактор) }
  LoadRiderLighting(LDummyEnv1, LKey, LFill, LDummyRKey, LDummyRFill);
  FPrevKey.Intensity := LKey;
  FPrevFill.Intensity := LFill;

  AVp.Camera.SetView(DefaultCamPos, DefaultCamDir.Normalize, DefaultCamUp);
end;

procedure TBikeFitPage.BuildLayout;
var
  Title: TCastleLabel;
  ResVpHost: TCastleUserInterface;
  BikeBlock, BikeRow: TCastleUserInterface;
  Cap: TCastleLabel;
  I: Integer;
begin
  FreePreviewBikes;
  if FPopupOverlay <> nil then
  begin
    if FPopupOverlay.Parent <> nil then
      FPopupOverlay.Parent.RemoveControl(FPopupOverlay);
    FPopupOverlay := nil;
  end;
  FPopupCard := nil;
  FPopupTitle := nil;
  FBikeFilter := nil;
  FPopupScroll := nil;
  FPopupList := nil;
  FPopupKind := PopupNone;
  FreeAndNil(FUiOwner);FValuePopup:=nil;FValueEdit:=nil;FValueRow:=0;
  FillChar(FValueButtons,SizeOf(FValueButtons),0);FillChar(FValueLabels,SizeOf(FValueLabels),0);
  FDyeStrip := nil;
  FDyePop := nil;
  FDyePopSlot := -1;
  FillChar(FDyeBtns, SizeOf(FDyeBtns), 0);
  FillChar(FDyePopSw, SizeOf(FDyePopSw), 0);
  FUiOwner := TComponent.Create(Self);
  FMainHost.ClearControls;

  { params left + result right — на всю высоту вкладки }
  FBottomRow := TCastleUserInterface.Create(FUiOwner);
  FBottomRow.FullSize := True;
  FMainHost.InsertFront(FBottomRow);

  { left: parameters only (no 3D bike) }
  FColParams := TCastleRectangleControl.Create(FUiOwner);
  FColParams.Color := MenuBackground;
  FColParams.FullSize := False;
  FColParams.WidthFraction := ParamsWidthFrac;
  FColParams.HeightFraction := 1.0;
  FColParams.Border.Right := 4;
  FColParams.Anchor(hpLeft, 0);
  FColParams.Anchor(vpMiddle, 0);
  FBottomRow.InsertFront(FColParams);

  Title := TMenuLabel.Create(FUiOwner);
  BindUiText(Title, 'Parameters');
  Title.Color := MenuText;
  Title.FontScale := 1.2;
  Title.Anchor(hpMiddle, 0);
  Title.Anchor(vpTop, -12);
  FColParams.InsertFront(Title);
  for I:=0 to High(FSectionButtons)do begin
    FSectionButtons[I]:=TMenuButton.Create(FUiOwner);
    FSectionButtons[I].Name:='BikeFitSection'+IntToStr(I);
    FSectionButtons[I].AutoIcon:=False;FSectionButtons[I].AutoSize:=False;
    FSectionButtons[I].Tag:=I;FSectionButtons[I].OnClick:=@ClickSection;
    FColParams.InsertFront(FSectionButtons[I]);
  end;
  BindUiText(FSectionButtons[0],'Bicycle');BindUiText(FSectionButtons[1],'Rider');
  BindUiText(FSectionButtons[2],'Appearance');

  BikeBlock := TCastleRectangleControl.Create(FUiOwner);
  TCastleRectangleControl(BikeBlock).Color := MenuSurface;
  BikeBlock.WidthFraction := 1.0;
  BikeBlock.Height := 78;
  BikeBlock.Border.Left := 10;
  BikeBlock.Border.Right := 10;
  BikeBlock.Anchor(hpMiddle, 0);
  BikeBlock.Anchor(vpTop, -48);
  FColParams.InsertFront(BikeBlock);
  FBikeControls:=BikeBlock;

  Cap := TMenuLabel.Create(FUiOwner);
  BindUiText(Cap, 'Bicycle');
  Cap.Color := MenuMuted;
  Cap.FontScale := 0.9;
  Cap.Anchor(hpLeft, 12);
  Cap.Anchor(vpTop, -8);
  BikeBlock.InsertFront(Cap);

  BikeRow := TCastleUserInterface.Create(FUiOwner);
  BikeRow.WidthFraction := 1.0;
  BikeRow.Height := 36;
  BikeRow.Border.Left := 8;
  BikeRow.Border.Right := 8;
  BikeRow.Anchor(hpMiddle, 0);
  BikeRow.Anchor(vpBottom, 8);
  BikeBlock.InsertFront(BikeRow);

  FBtnBikePick := MakeNavBtn(UiText('(none)  v'), @ClickBikePick, 180, 34);
  FBtnBikePick.FontScale := 0.85;
  FBtnBikePick.WidthFraction := 1.0;
  FBtnBikePick.Border.Right := 80;
  FBtnBikePick.Anchor(hpLeft, 0);
  FBtnBikePick.Anchor(vpMiddle, 0);
  BikeRow.InsertFront(FBtnBikePick);

  { size on top so the full-width bike button does not steal clicks }
  FBtnSizePick := MakeNavBtn('—  v', @ClickSizePick, 72, 34);
  FBtnSizePick.FontScale := 0.9;
  FBtnSizePick.Anchor(hpRight, 0);
  FBtnSizePick.Anchor(vpMiddle, 0);
  BikeRow.InsertFront(FBtnSizePick);

  FPopupOverlay := TMenuButton.Create(FUiOwner);
  FPopupOverlay.FullSize := True;
  FPopupOverlay.AutoSize := False;
  FPopupOverlay.Caption := '';
  FPopupOverlay.PaddingHorizontal := 0;
  FPopupOverlay.PaddingVertical := 0;
  FPopupOverlay.CustomBackground := True;
  FPopupOverlay.CustomColorNormal := Vector4(0, 0, 0, 0.55);
  FPopupOverlay.CustomColorFocused := Vector4(0, 0, 0, 0.55);
  FPopupOverlay.CustomColorPressed := Vector4(0, 0, 0, 0.55);
  FPopupOverlay.OnClick := @ClickPopupBg;
  FPopupOverlay.Exists := False;
  InsertFront(FPopupOverlay);

  FPopupCard := TMenuButton.Create(FUiOwner);
  FPopupCard.AutoSize := False;
  FPopupCard.Caption := '';
  FPopupCard.PaddingHorizontal := 0;
  FPopupCard.PaddingVertical := 0;
  FPopupCard.CustomBackground := True;
  FPopupCard.CustomColorNormal := MenuSurface;
  FPopupCard.CustomColorFocused := MenuSurface;
  FPopupCard.CustomColorPressed := MenuSurface;
  FPopupCard.OnClick := @ClickPopupCard;
  FPopupCard.Anchor(hpMiddle, 0);
  FPopupCard.Anchor(vpMiddle, 0);
  FPopupOverlay.InsertFront(FPopupCard);

  FPopupTitle := TMenuLabel.Create(FUiOwner);
  FPopupTitle.Color := MenuText;
  FPopupTitle.FontScale := 1.05;
  FPopupTitle.Anchor(hpLeft, 12);
  FPopupTitle.Anchor(vpTop, -10);
  FPopupCard.InsertFront(FPopupTitle);

  FBikeFilter := TMenuEdit.Create(FUiOwner);
  FBikeFilter.WidthFraction := 1.0;
  FBikeFilter.Border.Left := 10;
  FBikeFilter.Border.Right := 10;
  FBikeFilter.Height := 32;
  FBikeFilter.Anchor(hpMiddle, 0);
  FBikeFilter.Anchor(vpTop, -38);
  FBikeFilter.OnChange := @BikeFilterChange;
  FPopupCard.InsertFront(FBikeFilter);

  FPopupScroll := TMenuScrollView.Create(FUiOwner);
  FPopupScroll.FullSize := True;
  FPopupScroll.Border.Left := 8;
  FPopupScroll.Border.Right := 8;
  FPopupScroll.Border.Top := 78;
  FPopupScroll.Border.Bottom := 8;
  FPopupCard.InsertFront(FPopupScroll);

  FPopupList := TCastleVerticalGroup.Create(FUiOwner);
  FPopupList.Spacing := 2;
  FPopupList.Anchor(hpLeft, 0);
  FPopupList.Anchor(vpTop, 0);
  FPopupList.AutoSizeToChildren := True;
  FPopupScroll.ScrollArea.InsertFront(FPopupList);
  FPopupScroll.ScrollArea.AutoSizeToChildren := True;

  MakeFitRow(FColParams, UiText('Saddle height'), -134,
    FBtnSeatHDown, FBtnSeatHUp, FLblSeatH);
  FBtnSeatHDown.OnClick := @ClickSeatHDown;
  FBtnSeatHUp.OnClick := @ClickSeatHUp;

  MakeFitRow(FColParams, UiText('Saddle offset'), -172,
    FBtnSeatODown, FBtnSeatOUp, FLblSeatO);
  FBtnSeatODown.OnClick := @ClickSeatODown;
  FBtnSeatOUp.OnClick := @ClickSeatOUp;

  MakeFitRow(FColParams, UiText('Spacers'), -210,
    FBtnSpacersDown, FBtnSpacersUp, FLblSpacers);
  FBtnSpacersDown.OnClick := @ClickSpacersDown;
  FBtnSpacersUp.OnClick := @ClickSpacersUp;

  MakeFitRow(FColParams, UiText('Stem'), -248,
    FBtnStemDown, FBtnStemUp, FLblStem);
  FBtnStemDown.OnClick := @ClickStemDown;
  FBtnStemUp.OnClick := @ClickStemUp;

  MakeFitRow(FColParams, UiText('Height'), -286,
    FBtnHeightDown, FBtnHeightUp, FLblHeight);
  FBtnHeightDown.OnClick := @ClickHeightDown;
  FBtnHeightUp.OnClick := @ClickHeightUp;

  MakeFitRow(FColParams, UiText('Inseam'), -324,
    FBtnInseamDown, FBtnInseamUp, FLblInseam);
  FBtnInseamDown.OnClick := @ClickInseamDown;
  FBtnInseamUp.OnClick := @ClickInseamUp;

  MakeFitRow(FColParams, UiText('Body build'), -362,
    FBtnBulkDown, FBtnBulkUp, FLblBulk);
  FBtnBulkDown.OnClick := @ClickBulkDown;
  FBtnBulkUp.OnClick := @ClickBulkUp;

  MakeFitRow(FColParams, UiText('Abdomen'), -400,
    FBtnBellyDown, FBtnBellyUp, FLblBelly);
  FBtnBellyDown.OnClick := @ClickBellyDown;
  FBtnBellyUp.OnClick := @ClickBellyUp;

  MakeFitRow(FColParams, UiText('Knees'), -438,
    FBtnKneeDown, FBtnKneeUp, FLblKnee);
  FBtnKneeDown.OnClick := @ClickKneeDown;
  FBtnKneeUp.OnClick := @ClickKneeUp;

  MakeFitRow(FColParams, UiText('Feet'), -476,
    FBtnAnkleDown, FBtnAnkleUp, FLblAnkle);
  FBtnAnkleDown.OnClick := @ClickAnkleDown;
  FBtnAnkleUp.OnClick := @ClickAnkleUp;

  FCadenceControls:=MakeParamBlock(FColParams, UiText('Cadence (preview)'), -520,
    FBtnCadenceDown, FBtnCadenceUp, FLblCadence);
  FBtnCadenceDown.Caption := '−';
  FBtnCadenceUp.Caption := '+';
  FBtnCadenceDown.OnClick := @ClickCadenceDown;
  FBtnCadenceUp.OnClick := @ClickCadenceUp;

  { right: result with riding animation + auto pose cycle }
  FColResult := TCastleRectangleControl.Create(FUiOwner);
  FColResult.Color := MenuBackground;
  FColResult.FullSize := False;
  FColResult.WidthFraction := ResultWidthFrac;
  FColResult.HeightFraction := 1.0;
  FColResult.Border.Left := 4;
  FColResult.Anchor(hpRight, 0);
  FColResult.Anchor(vpMiddle, 0);
  FBottomRow.InsertFront(FColResult);

  Title := TMenuLabel.Create(FUiOwner);
  BindUiText(Title, 'Result');
  Title.Color := MenuText;
  Title.FontScale := 1.2;
  Title.Anchor(hpMiddle, 0);
  Title.Anchor(vpTop, -10);
  FColResult.InsertFront(Title);

  ResVpHost := TCastleUserInterface.Create(FUiOwner);
  ResVpHost.FullSize := True;
  ResVpHost.Border.Left := 8;
  ResVpHost.Border.Right := 8;
  ResVpHost.Border.Top := 38;
  ResVpHost.Border.Bottom := ResultBarH + 6;
  FColResult.InsertFront(ResVpHost);
  SetupViewport(FVpResult, FNavResult, ResVpHost);
  FPreviewItems := FVpResult.Items;

  FFitOverlay := TCastleRectangleControl.Create(FUiOwner);
  FFitOverlay.Color := Vector4(0.04, 0.07, 0.06, 0.72);
  FFitOverlay.Width := 158;
  FFitOverlay.Height := 56;
  FFitOverlay.Anchor(hpLeft, 10);
  FFitOverlay.Anchor(vpTop, -8);
  ResVpHost.InsertFront(FFitOverlay);

  FLblReach := TMenuLabel.Create(FUiOwner);
  BindUiText(FLblReach, 'Reach  —');
  FLblReach.Color := MenuText;
  FLblReach.FontScale := 0.95;
  FLblReach.Anchor(hpLeft, 10);
  FLblReach.Anchor(vpTop, -8);
  FFitOverlay.InsertFront(FLblReach);

  FLblStack := TMenuLabel.Create(FUiOwner);
  BindUiText(FLblStack, 'Stack  —');
  FLblStack.Color := MenuText;
  FLblStack.FontScale := 0.95;
  FLblStack.Anchor(hpLeft, 10);
  FLblStack.Anchor(vpBottom, 8);
  FFitOverlay.InsertFront(FLblStack);

  { current pose name (auto-cycled, no manual arrows) }
  FLblPose := TMenuLabel.Create(FUiOwner);
  FLblPose.Color := MenuText;
  FLblPose.FontScale := 1.0;
  FLblPose.Anchor(hpMiddle, 0);
  FLblPose.Anchor(vpBottom, 10);
  FLblPose.MaxWidth := 420;
  FColResult.InsertFront(FLblPose);
  FPosePrev:=MakeNavBtn('‹',@ClickPose,38,30);FPosePrev.Name:='BikeFitPreviousPose';FPosePrev.Tag:=-1;
  FPosePrev.Anchor(hpLeft,12);FPosePrev.Anchor(vpBottom,45);FColResult.InsertFront(FPosePrev);
  FPoseNext:=MakeNavBtn('›',@ClickPose,38,30);FPoseNext.Name:='BikeFitNextPose';FPoseNext.Tag:=1;
  FPoseNext.Anchor(hpLeft,58);FPoseNext.Anchor(vpBottom,45);FColResult.InsertFront(FPoseNext);
  FPoseToggle:=MakeNavBtn(UiText('Auto poses'),@ClickPose,150,30);FPoseToggle.Tag:=0;FPoseToggle.Name:='BikeFitAutoPose';
  FPoseToggle.Anchor(hpLeft,104);FPoseToggle.Anchor(vpBottom,45);FColResult.InsertFront(FPoseToggle);
  FRiderParams:=MakeNavBtn(UiText('Weight and FTP'),@ClickRiderParams,190,32);
  FRiderParams.Name:='BikeFitRiderParams';FRiderParams.Anchor(hpLeft,14);FRiderParams.Anchor(vpBottom,112);
  FColParams.InsertFront(FRiderParams);

  FLblResultInfo := TMenuLabel.Create(FUiOwner);
  FLblResultInfo.Color := MenuMuted;
  FLblResultInfo.FontScale := 0.8;
  FLblResultInfo.Exists:=False;
  FLblResultInfo.Anchor(hpLeft, 12);
  FLblResultInfo.Anchor(vpBottom, 12);
  FColResult.InsertFront(FLblResultInfo);

  { оверлей цветов одежды/кожи/волос + рамы/ободьев — слева на результате }
  BuildColorStrip;
  LayoutSections;
end;

procedure TBikeFitPage.FitCameraToItems(AVp: TCastleViewport);
var
  Box: TBox3D;
  BoxCenter, Dir: TVector3;
  Radius, Dist: Single;
begin
  if FLiveRide then
  begin
    UpdateLiveCamera(True);
    Exit;
  end;
  if AVp = nil then Exit;
  Box := AVp.Items.BoundingBox;
  if Box.IsEmpty then
  begin
    AVp.Camera.SetView(DefaultCamPos, DefaultCamDir.Normalize, DefaultCamUp);
    Exit;
  end;
  BoxCenter := Box.Center;
  Radius := Box.AverageSize * 0.5;
  if Radius < 0.3 then Radius := 0.3;
  { ближе к модели — крупнее в viewport }
  Dist := Radius * 2.75;
  Dir := Vector3(0.55, -0.22, 0.8).Normalize;
  AVp.Camera.SetView(BoxCenter - Dir * Dist, Dir, DefaultCamUp);
end;

procedure TBikeFitPage.FreePreviewBikes;
begin
  if FLiveRide then
  begin
    { The extra camera is ours; the shared world and bike remain in the ride. }
    if (FVpResult <> nil) and (FPreviewItems <> nil) then
    begin
      FVpResult.Items.Remove(FVpResult.Camera);
      FVpResult.Background := nil;
      FVpResult.Items := FPreviewItems;
      FPreviewItems.Add(FVpResult.Camera);
    end;
    FResultBike := nil;
    FLiveRide := False;
    FLiveSettingsDirty := False;
  end else
  if FResultBike <> nil then
  begin
    if FVpResult <> nil then FVpResult.Items.Remove(FResultBike.Group);
    FreeAndNil(FResultBike);
  end;
end;

procedure TBikeFitPage.AttachLiveRide;
begin
  FreePreviewBikes;
  FResultBike := ViewPlay.Bike;
  FLiveRide := FResultBike <> nil;
  if not FLiveRide then Exit;
  FPreviewItems.Remove(FVpResult.Camera);
  FVpResult.Items := ViewPlay.MainViewport.Items;
  FVpResult.Items.Add(FVpResult.Camera);
  FVpResult.BackgroundColor := ViewPlay.MainViewport.BackgroundColor;
  FVpResult.Background := ViewPlay.MainViewport.Background;
  FNavResult.CheckCollisions := False;
  ReadFitAdjustments(FResultBike, FFitSeatExt, FFitSaddleOff,
    FFitSpacers, FFitStem);
  FFitKneeFlare := FResultBike.TripoKneeFlare;
  FFitAnkleFlex := FResultBike.TripoAnkleFlex;
  FFitInited := True;
  FOrigFrameC := FResultBike.LastBuildColors.Frame;
  FOrigRimC := FResultBike.LastBuildColors.Rim;
  FCadenceRpm := ViewPlay.RideCadence;
  BindUiText(FButtonApply, 'Save');
  UpdateLiveCamera(True);
  FDirtyResult := False;
end;

procedure TBikeFitPage.UpdateLiveCamera(const Reset: Boolean);
var
  RiderCenter, P, D, U, Extent, ForwardDir, SideDir: TVector3;
begin
  if not FLiveRide or (FResultBike = nil) then Exit;
  RiderCenter := FResultBike.Group.WorldTransform.MultPoint(TVector3.Zero) +
    Vector3(0, 0.8, 0);
  { A rider-sized box, excluding the world's terrain and shadow receivers. }
  Extent := Vector3(1.3, 0.9, 1.3);
  FNavResult.ModelBox := Box3D(RiderCenter - Extent, RiderCenter + Extent);
  if Reset then
  begin
    ForwardDir := ViewPlay.AvatarTransform.Direction;
    ForwardDir.Y := 0;
    if ForwardDir.Length < 0.001 then ForwardDir := Vector3(0, 0, 1)
    else ForwardDir := ForwardDir.Normalize;
    SideDir := TVector3.CrossProduct(ForwardDir, DefaultCamUp);
    D := (ForwardDir * 0.45 - SideDir * 0.85 + Vector3(0, -0.25, 0)).Normalize;
    FVpResult.Camera.SetWorldView(RiderCenter - D * 3.4, D, DefaultCamUp);
  end else
  begin
    FVpResult.Camera.GetWorldView(P, D, U);
    FVpResult.Camera.SetWorldView(P + RiderCenter - FLastLiveCenter, D, U);
  end;
  FLastLiveCenter := RiderCenter;
end;

procedure TBikeFitPage.LiveFitChanged;
begin
  if not FLoadingPreview then begin FLiveSettingsDirty:=True;FFitSaveDelay:=1.2;end;
  if FLiveRide then ViewPlay.BikeFitChanged;
end;

procedure TBikeFitPage.BeforeRender;
begin
  inherited;
  { Follow after the ride update so both views see the same rider position. }
  UpdateLiveCamera(False);
end;

procedure TBikeFitPage.PageShown;
var
  I: Integer;
  Want: string;
begin
  if FLoadingPreview then
  begin
    FReleasePreviewPending := False;
    Exit;
  end;
  if FLabelTitle <> nil then
    FLabelTitle.Exists := False;
  if FButtonBack <> nil then
    FButtonBack.Exists := False;
  BindUiText(FButtonApply, 'Save bike fit');FButtonApply.Exists:=False;FPoseAuto:=False;
  FCadenceRpm := 80;
  FPoseTimer := 0;
  FPoseCycleSec := DefaultPoseCycleSec;
  FPoseBlendSec := DefaultPoseBlendSec;
  if Settings.FitParamsValid then
  begin
    FFitSeatExt := Settings.FitSeatpostExt;
    FFitSaddleOff := Settings.FitSaddleOffset;
    FFitSpacers := Settings.FitHeadsetSpacer;
    FFitStem := Settings.FitStemLength;
    FFitHeightCm := Settings.FitHeightCm;
    FFitInseamCm := Settings.FitInseamCm;
    FFitBulk := Settings.FitBulk;
    FFitBelly := Settings.FitBelly;
    FFitKneeFlare := Settings.FitKneeFlare;
    FFitAnkleFlex := Settings.FitAnkleFlex;
    FFitInited := True;
    { 100 cm is the 1 m Tripo file mesh, not a real standing height. }
    if (FFitHeightCm >= 130) and (FFitHeightCm <= 230) then
      FSeededRestH := -1
    else
      FSeededRestH := 0;
  end
  else
  begin
    FFitInited := False;
    FSeededRestH := 0;
  end;

  if FUiOwner = nil then
    BuildLayout;
  LayoutSections;
  LoadBikeFitColors;   { восстановить цвета одежды/байка из настроек }

  ScanLibraries;

  FSelBike := -1;
  Want := Settings.SelectedBikeJson;
  if Want <> '' then
    for I := 0 to FBikePaths.Count - 1 do
      if SameText(FBikePaths[I], Want) or
         SameText(ExtractFileName(FBikePaths[I]), ExtractFileName(Want)) then
      begin
        FSelBike := I;
        Break;
      end;
  if (FSelBike < 0) and (FBikePaths.Count > 0) then FSelBike := 0;
  LoadSelectedInsights;
  Want := Settings.SelectedBikeSize;
  FSelSize := -1;
  if Want <> '' then
    for I := 0 to FSizeNames.Count - 1 do
      if SameText(FSizeNames[I], Want) then
      begin
        FSelSize := I;
        Break;
      end;
  if (FSelSize < 0) and (FSizeNames.Count > 0) then FSelSize := 0;

  if Assigned(ViewPlay) and ViewPlay.SessionAlive and ViewMenu.RideUnderneath then
    AttachLiveRide
  else
    FDirtyResult := True;
  FBtnCadenceDown.Enabled := not FLiveRide;
  FBtnCadenceUp.Enabled := not FLiveRide;
  if FCadenceCaption <> nil then
    if FLiveRide then BindUiText(FCadenceCaption, 'Ride cadence')
    else BindUiText(FCadenceCaption, 'Cadence (preview)');
  UpdateLabels;
end;

procedure TBikeFitPage.PageHidden;
begin
  { Bike BuildYield can dispatch a queued tab switch. Release the scene only
    after the active rebuild returns, never from inside that rebuild. }
  if FLoadingPreview then
  begin
    FReleasePreviewPending := True;
    Exit;
  end;
  if FLiveSettingsDirty then ClickApply(nil);
  CancelValue(nil);ClosePopup;
  CloseDyePopup;
  FWantRiderPath := '';
  if FGlbWorker <> nil then
  begin
    FGlbWorker.WaitFor;
    FreeAndNil(FGlbWorker);
  end;
  FreePreviewBikes;
  FCachedBikeUrl := '';
  FCachedBikeJson := '';
end;

function TBikeFitPage.CurrentRiderPath: string;
begin
  Result := ResolveRiderGlbPath(Settings.SelectedRiderGlb);
  if Result = '' then
    Result := ResolveRiderGlbPath(RiderGlbUrlForGender(Settings.GetGender));
end;

function TBikeFitPage.CurrentRiderName: string;
begin
  if SameText(Settings.GetGender, 'female') then
    Result := 'FEM'
  else
    Result := 'MEN';
end;

procedure TBikeFitPage.ScanLibraries;
begin
  FBikePaths.Clear;
  FBikeNames.Clear;
  ScanInsightsCatalog(FBikePaths, FBikeNames);
  Logger.Info(Format('[BikeFit] library rider=%s bikes=%d dir=%s',
    [CurrentRiderName, FBikePaths.Count, InsightsCatalogDir]));
end;

function TBikeFitPage.CurrentBikeCaption: string;
begin
  if (FSelBike >= 0) and (FSelBike < FBikeNames.Count) then
    Result := FBikeNames[FSelBike]
  else
    Result := UiText('(none)');
end;

function TBikeFitPage.CurrentSizeName: string;
begin
  if (FSelSize >= 0) and (FSelSize < FSizeNames.Count) then
    Result := FSizeNames[FSelSize]
  else
    Result := '';
end;

function TBikeFitPage.CurrentSizeCaption: string;
begin
  if CurrentSizeName <> '' then
    Result := CurrentSizeName
  else
    Result := '—';
end;

procedure TBikeFitPage.ClosePopup;
begin
  FPopupKind := PopupNone;
  if FPopupOverlay <> nil then
    FPopupOverlay.Exists := False;
end;

procedure TBikeFitPage.ClickPopupBg(Sender: TObject);
begin
  ClosePopup;
end;

procedure TBikeFitPage.ClickPopupCard(Sender: TObject);
begin
  { swallow }
end;

procedure TBikeFitPage.FillBikePopupList;
var
  Filter, BikeName: string;
  I, Shown, Hidden: Integer;
  Btn: TCastleButton;
  Hint: TCastleLabel;
begin
  if FPopupList = nil then Exit;
  FPopupList.ClearControls;
  if FBikeFilter <> nil then
    Filter := LowerCase(Trim(FBikeFilter.Text))
  else
    Filter := '';
  Shown := 0;
  Hidden := 0;
  for I := 0 to FBikeNames.Count - 1 do
  begin
    BikeName := FBikeNames[I];
    if (Filter <> '') and (Pos(Filter, LowerCase(BikeName)) = 0) then
      Continue;
    if Shown >= BikePopupMaxRows then
    begin
      Inc(Hidden);
      Continue;
    end;
    Btn := TMenuButton.Create(FUiOwner);
    Btn.Caption := BikeName;
    Btn.AutoSize := False;
    Btn.Width := 400;
    Btn.Height := 28;
    Btn.FontScale := 0.85;
    Btn.CustomBackground := True;
    if I = FSelBike then
      Btn.CustomColorNormal := Vector4(0.13,0.30,0.34,1)
    else
      Btn.CustomColorNormal := Vector4(0.105,0.157,0.192,1);
    Btn.CustomColorFocused := Vector4(0.15,0.23,0.28,1);
    Btn.CustomColorPressed := Vector4(0.13,0.30,0.34,1);
    Btn.Tag := I;
    Btn.OnClick := @ClickPopupBike;
    FPopupList.InsertBack(Btn);
    Inc(Shown);
  end;
  if Hidden > 0 then
  begin
    Hint := TMenuLabel.Create(FUiOwner);
    Hint.Caption := Format(UiText('%d more — refine your search'), [Hidden]);
    Hint.Color := MenuMuted;
    Hint.FontScale := 0.8;
    FPopupList.InsertBack(Hint);
  end
  else if Shown = 0 then
  begin
    Hint := TMenuLabel.Create(FUiOwner);
    BindUiText(Hint, 'no results');
    Hint.Color := MenuMuted;
    Hint.FontScale := 0.85;
    FPopupList.InsertBack(Hint);
  end;
end;

procedure TBikeFitPage.FillSizePopupList;
var
  I: Integer;
  Btn: TCastleButton;
begin
  if FPopupList = nil then Exit;
  FPopupList.ClearControls;
  for I := 0 to FSizeNames.Count - 1 do
  begin
    Btn := TMenuButton.Create(FUiOwner);
    Btn.Caption := FSizeNames[I];
    Btn.AutoSize := False;
    Btn.Width := 88;
    Btn.Height := 28;
    Btn.FontScale := 0.9;
    Btn.CustomBackground := True;
    if I = FSelSize then
      Btn.CustomColorNormal := Vector4(0.13,0.30,0.34,1)
    else
      Btn.CustomColorNormal := Vector4(0.105,0.157,0.192,1);
    Btn.CustomColorFocused := Vector4(0.15,0.23,0.28,1);
    Btn.CustomColorPressed := Vector4(0.13,0.30,0.34,1);
    Btn.Tag := I;
    Btn.OnClick := @ClickPopupSize;
    FPopupList.InsertBack(Btn);
  end;
end;

procedure TBikeFitPage.OpenBikePopup;
begin
  if FPopupOverlay = nil then Exit;
  FPopupKind := PopupBike;
  FPopupCard.Width := 440;
  FPopupCard.Height := 480;
  FPopupTitle.Caption := Format(UiText('Bike  (%d)'), [FBikeNames.Count]);
  FBikeFilter.Exists := True;
  FBikeFilter.Text := '';
  FPopupScroll.Border.Top := 78;
  FillBikePopupList;
  FPopupOverlay.Exists := True;
end;

procedure TBikeFitPage.OpenSizePopup;
var
  Hint: TCastleLabel;
  Rows: Integer;
begin
  if FPopupOverlay = nil then Exit;
  if FSizeNames.Count = 0 then
    LoadSelectedInsights;
  FPopupKind := PopupSize;
  Rows := Max(1, FSizeNames.Count);
  FPopupCard.Width := 140;
  FPopupCard.Height := Min(360, 52 + Rows * 32);
  BindUiText(FPopupTitle, 'Size');
  FBikeFilter.Exists := False;
  FPopupScroll.Border.Top := 38;
  FillSizePopupList;
  if (FPopupList <> nil) and (FSizeNames.Count = 0) then
  begin
    Hint := TMenuLabel.Create(FUiOwner);
    BindUiText(Hint, 'no sizes');
    Hint.Color := MenuMuted;
    Hint.FontScale := 0.85;
    FPopupList.InsertBack(Hint);
  end;
  FPopupOverlay.Exists := True;
end;

procedure TBikeFitPage.BikeFilterChange(Sender: TObject);
begin
  if FPopupKind = PopupBike then
    FillBikePopupList;
end;

procedure TBikeFitPage.ClickBikePick(Sender: TObject);
begin
  if FPopupKind = PopupBike then
    ClosePopup
  else
    OpenBikePopup;
end;

procedure TBikeFitPage.ClickSizePick(Sender: TObject);
begin
  if FPopupKind = PopupSize then
    ClosePopup
  else
    OpenSizePopup;
end;

procedure TBikeFitPage.LoadSelectedInsights;
var
  Url: string;
  T0: QWord;
begin
  FSizeNames.Clear;
  FreeAndNil(FGeoList);
  FModelInfo := Default(TBikeModelInfo);
  if (FSelBike < 0) or (FSelBike >= FBikePaths.Count) then Exit;
  Url := FBikePaths[FSelBike];
  T0 := GetTickCount64;
  try
    if not ExtractBikeInsights(Url, FModelInfo, FGeoList) then
    begin
      Logger.Info('[BikeFit] insights parse fail ' + Url);
      Exit;
    end;
    CollectInsightSizes(FGeoList, FSizeNames);
    if (FSelBike >= 0) and (FSelBike < FBikeNames.Count) then
      FBikeNames[FSelBike] := InsightsModelCaption(FModelInfo, Url);
    Logger.Info(Format('[BikeFit] insights %s sizes=%d %d ms',
      [ExtractFileName(Url), FSizeNames.Count, GetTickCount64 - T0]));
  except
    on E: Exception do
    begin
      FreeAndNil(FGeoList);
      FSizeNames.Clear;
      Logger.Info('[BikeFit] insights exception ' + E.Message + ' url=' + Url);
    end;
  end;
end;

procedure TBikeFitPage.ClickPopupBike(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := (Sender as TCastleButton).Tag;
  ClosePopup;
  if (Idx < 0) or (Idx >= FBikePaths.Count) then Exit;
  if Idx = FSelBike then Exit;
  FSelBike := Idx;
  FSelSize := -1;
  LoadSelectedInsights;
  if FSizeNames.Count > 0 then
    FSelSize := 0;
  FSelPose := 0;
  FPoseTimer := 0;
  FDirtyResult := True;
  FLiveSettingsDirty:=True;FFitSaveDelay:=1.2;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickPopupSize(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := (Sender as TCastleButton).Tag;
  ClosePopup;
  if (Idx < 0) or (Idx >= FSizeNames.Count) then Exit;
  if Idx = FSelSize then Exit;
  FSelSize := Idx;
  FSelPose := 0;
  FPoseTimer := 0;
  FDirtyResult := True;
  FLiveSettingsDirty:=True;FFitSaveDelay:=1.2;
  UpdateLabels;
end;

function TBikeFitPage.EnsureBikeJson: Boolean;
var
  Url, Fn: string;
  SL: TStringList;
  T0: QWord;
begin
  Result := False;
  Url := BaseBikeUrl;
  if (Url = FCachedBikeUrl) and (FCachedBikeJson <> '') then
    Exit(True);
  Fn := URIToFilenameSafe(Url);
  if (Fn = '') or (not FileExists(Fn)) then
    Fn := Url;
  SL := TStringList.Create;
  try
    T0 := GetTickCount64;
    SL.LoadFromFile(Fn);
    FCachedBikeUrl := Url;
    FCachedBikeJson := SL.Text;
    Logger.Info(Format('[BikeFit] bike JSON %s %d ms (%d bytes)',
      [ExtractFileName(Fn), GetTickCount64 - T0, Length(FCachedBikeJson)]));
    Result := True;
  except
    on E: Exception do
    begin
      FCachedBikeUrl := '';
      FCachedBikeJson := '';
      Logger.Info('[BikeFit] bike JSON fail: ' + E.Message);
    end;
  end;
  SL.Free;
end;

procedure TBikeFitPage.LoadPoseNames;
var I: Integer; P: TRiderPose;
begin
  FPoseNames.Clear;
  for I := 0 to BuiltinRiderPoseCount - 1 do
  begin
    P := BuiltinRiderPose(I);
    if not P.Special then FPoseNames.AddObject(P.Name, TObject(PtrInt(I)));
  end;
end;

procedure TBikeFitPage.ApplyCadenceToResult;
var
  CrankIntv: Single;
  SpeedMps: Single;
begin
  if FLiveRide or (FResultBike = nil) then Exit;
  if FCadenceRpm < 1 then
  begin
    { stop pedaling — same convention as gameviewplay (huge interval) }
    FResultBike.SetAnimationSpeed(9999, 9999);
    FResultBike.SetWheelSpeedMps(0);
    Exit;
  end;
  { period of one crank revolution, seconds — same as play/remote riders }
  CrankIntv := 60.0 / FCadenceRpm;
  FResultBike.SetAnimationSpeed(CrankIntv, CrankIntv);
  { rough road speed for wheel spin (~5.5 m per crank rev at mid gear) }
  SpeedMps := (FCadenceRpm / 60.0) * 5.5;
  FResultBike.SetWheelSpeedMps(SpeedMps);
end;

procedure TBikeFitPage.ApplySelectedRiderOnly;
var
  Rider: string;
  T0: QWord;
  Ok: Boolean;
begin
  if FResultBike = nil then
  begin
    FDirtyResult := True;
    Exit;
  end;
  Rider := CurrentRiderPath;
  if Rider = '' then Exit;
  T0 := GetTickCount64;
  try
    Ok := FResultBike.LoadTripoRider(Rider);
  except
    on E: Exception do
    begin
      Logger.Info('[BikeFit] LoadTripoRider EXC ' + ExtractFileName(Rider) +
        ': ' + E.ClassName + ' ' + E.Message);
      raise;
    end;
  end;
  if (FResultBike <> nil) and (FResultBike.TripoRider <> nil) then
    Logger.Info(Format('[BikeFit] LoadTripoRider %s ok=%s restH=%.3f m %d ms',
      [ExtractFileName(Rider), BoolToStr(Ok, True),
       FResultBike.TripoRider.RestHeight, GetTickCount64 - T0]))
  else
    Logger.Info(Format('[BikeFit] LoadTripoRider %s ok=%s %d ms',
      [ExtractFileName(Rider), BoolToStr(Ok, True), GetTickCount64 - T0]));
  ApplyRiderShapeToPreview;
  FitCameraToItems(FVpResult);
  ApplyCadenceToResult;
  FPoseTimer := 0;
  ApplyResultPose;
  ReapplyHelmetColor;
end;

procedure TBikeFitPage.RequestResultRider(const APath: string);
begin
  FWantRiderPath := APath;
  if APath = '' then Exit;
  if (FGlbWorker <> nil) and FGlbWorker.Finished and
     SameText(FGlbWorker.Path, APath) then
  begin
    PumpResultRiderLoad;
    Exit;
  end;
  if (FGlbWorker <> nil) and (not FGlbWorker.Finished) then
    Exit; { keep current worker; Pump discards if path mismatches }
  if FGlbWorker <> nil then
    FreeAndNil(FGlbWorker);
  Logger.Info('[BikeFit] prefetch ' + ExtractFileName(APath));
  FGlbWorker := TTripoGlbWorker.Create(APath);
end;

procedure TBikeFitPage.PumpResultRiderLoad;
var
  Prep: TTripoGlbPrepared;
  T0: QWord;
  Ok: Boolean;
begin
  if FGlbWorker = nil then
  begin
    if FWantRiderPath <> '' then
      RequestResultRider(FWantRiderPath);
    Exit;
  end;
  if not FGlbWorker.Finished then Exit;
  if FWantRiderPath = '' then Exit; { idle prefetch of the next rider }
  if not SameText(FGlbWorker.Path, FWantRiderPath) then
  begin
    FreeAndNil(FGlbWorker);
    RequestResultRider(FWantRiderPath);
    Exit;
  end;

  Prep := FGlbWorker.Prepared;
  FGlbWorker.Prepared := nil;
  FreeAndNil(FGlbWorker);
  if (Prep = nil) or (not Prep.Ok) then
  begin
    if Prep <> nil then
      Logger.Info('[BikeFit] prefetch fail ' + ExtractFileName(FWantRiderPath) +
        ' ' + Prep.Error)
    else
      Logger.Info('[BikeFit] prefetch fail ' + ExtractFileName(FWantRiderPath));
    FreeAndNil(Prep);
    if FResultBike <> nil then
      ApplySelectedRiderOnly;
    FWantRiderPath := '';
    Exit;
  end;
  if FResultBike = nil then
  begin
    FreeAndNil(Prep);
    FDirtyResult := True;
    Exit;
  end;
  T0 := GetTickCount64;
  Ok := FResultBike.LoadTripoRiderPrepared(Prep);
  if (FResultBike <> nil) and (FResultBike.TripoRider <> nil) then
    Logger.Info(Format('[BikeFit] LoadPrepared %s ok=%s restH=%.3f m %d ms',
      [ExtractFileName(Prep.Path), BoolToStr(Ok, True),
       FResultBike.TripoRider.RestHeight, GetTickCount64 - T0]))
  else
    Logger.Info(Format('[BikeFit] LoadPrepared %s ok=%s %d ms',
      [ExtractFileName(Prep.Path), BoolToStr(Ok, True), GetTickCount64 - T0]));
  FreeAndNil(Prep);
  FWantRiderPath := '';
  T0 := GetTickCount64;
  ApplyRiderShapeToPreview;
  Logger.Info(Format('[BikeFit]   ApplyRiderShape %d ms', [GetTickCount64 - T0]));
  T0 := GetTickCount64;
  FitCameraToItems(FVpResult);
  Logger.Info(Format('[BikeFit]   FitCamera %d ms', [GetTickCount64 - T0]));
  T0 := GetTickCount64;
  ApplyCadenceToResult;
  FPoseTimer := 0;
  ApplyResultPose;
  ReapplyHelmetColor;
  Logger.Info(Format('[BikeFit]   Pose %d ms', [GetTickCount64 - T0]));
  UpdateLabels;
end;

procedure TBikeFitPage.ReloadResultPreview;
var
  Url, JsonText, Rider: string;
  T0: QWord;
  S: TClothSlot;
begin
  FDirtyResult := False;
  if FLiveRide then
  begin
    if (FSelBike >= 0) and (FSelBike < FBikePaths.Count) then
      if ApplyInsightsFileToBikeInstance(FResultBike, FBikePaths[FSelBike],
        CurrentSizeName) then
      begin
        ApplyFitToPreview;
        ReapplyColorsAfterBuild;
        LiveFitChanged;
      end;
    UpdateLabels;
    Exit;
  end;
  if FResultBike <> nil then
  begin
    FVpResult.Items.Remove(FResultBike.Group);
    FreeAndNil(FResultBike);
  end;
  if not EnsureBikeJson then Exit;

  Url := BaseBikeUrl;
  LoadPoseNames;
  if FSelPose >= FPoseNames.Count then FSelPose := 0;
  if FSelPose < 0 then FSelPose := 0;

  JsonText := FCachedBikeJson;
  Rider := CurrentRiderPath;
  Logger.Info('[BikeFit] rider path=' + Rider +
    ' exists=' + BoolToStr((Rider <> '') and FileExists(Rider), True));
  if Rider <> '' then
    JsonText := InjectRiderPath(JsonText, Rider);

  T0 := GetTickCount64;
  try
    { Bike first, rider after dye preset: ClothDye hangs on the rider-only
      graph (FinishLoadAfterGraph), same as the editor. GpuAnim=False is
      CGE TSkinNode + UpdatePose — that is the editor's animation, not a
      CPU fallback for dye. }
    FResultBike := LoadBikeInstanceFromJSONString(JsonText, FUiOwner,
      15.0, 40.0, 80.0, False);
    if FResultBike <> nil then
    begin
      FResultBike.GpuAnim := False;
      FResultBike.ClothDyePresetMode := cdmShader;
      for S := Low(TClothSlot) to High(TClothSlot) do
        if FDyeOn[S] then
          FResultBike.StageRiderClothColor(S, FDyeColor[S]);
      AttachTripoRiderFromJSON(FResultBike, JsonText);
    end;
  except
    on E: Exception do
    begin
      Logger.Info('[BikeFit] result load fail: ' + E.Message);
      FResultBike := nil;
      Exit;
    end;
  end;
  Logger.Info(Format('[BikeFit] LoadBikeInstanceFromJSONString %d ms (bike rebuild + GLB)',
    [GetTickCount64 - T0]));
  if (FResultBike <> nil) and (FSelBike >= 0) and (FSelBike < FBikePaths.Count) then
  begin
    T0 := GetTickCount64;
    if ApplyInsightsFileToBikeInstance(FResultBike, FBikePaths[FSelBike],
      CurrentSizeName) then
      Logger.Info(Format('[BikeFit] apply insights %s size=%s %d ms',
        [ExtractFileName(FBikePaths[FSelBike]), CurrentSizeName,
         GetTickCount64 - T0]))
    else
      Logger.Info('[BikeFit] apply insights failed ' + FBikePaths[FSelBike]);
  end;
  if FResultBike <> nil then
  begin
    T0 := GetTickCount64;
    SyncFitFromBikeIfNeeded;
    ApplyFitToPreview;
    Logger.Info(Format('[BikeFit]   ApplyFit %d ms', [GetTickCount64 - T0]));
    FVpResult.Items.Add(FResultBike.Group);
    T0 := GetTickCount64;
    ReapplyColorsAfterBuild;   { цвета одежды/рамы/ободьев на свежий билд }
    Logger.Info(Format('[BikeFit]   ReapplyColors/shader %d ms', [GetTickCount64 - T0]));
    T0 := GetTickCount64;
    FitCameraToItems(FVpResult);
    ApplyCadenceToResult;
    FPoseTimer := 0;
    ApplyResultPose;
    Logger.Info(Format('[BikeFit]   FitCam/pose %d ms', [GetTickCount64 - T0]));
  end;
  UpdateLabels;
end;

procedure TBikeFitPage.ApplyResultPose;
var P: TRiderPose; Idx: Integer;
begin
  if FLiveRide or (FResultBike = nil) then Exit;
  if (FSelPose < 0) or (FSelPose >= FPoseNames.Count) then Exit;
  Idx := PtrInt(FPoseNames.Objects[FSelPose]);
  P := BuiltinRiderPose(Idx);
  P.KneeFlare := FFitKneeFlare;
  P.AnkleFlex := FFitAnkleFlex;
  FResultBike.ApplyRiderPose(P, Max(0.05, FPoseBlendSec));
end;

procedure TBikeFitPage.AdvancePoseCycle;
begin
  if FPoseNames.Count <= 1 then Exit;
  Inc(FSelPose);
  if FSelPose >= FPoseNames.Count then
    FSelPose := 0;
  ApplyResultPose;
  UpdateLabels;
end;

procedure TBikeFitPage.LanguageChanged(Sender: TObject);
begin
  UpdateLabels;
end;

procedure TBikeFitPage.UpdateLabels;
var
  RiderName, BikeName, PoseName: string;I:Integer;
begin
  RiderName := CurrentRiderName;

  if (FSelBike >= 0) and (FSelBike < FBikeNames.Count) then
    BikeName := FBikeNames[FSelBike]
  else
    BikeName := UiText('(none)');

  if (FSelPose >= 0) and (FSelPose < FPoseNames.Count) then
    PoseName := FPoseNames[FSelPose]
  else
    PoseName := 'Default';

  if FBtnBikePick <> nil then
    FBtnBikePick.Caption := MenuEllipsis(CurrentBikeCaption, FBtnBikePick.Font,
      Max(40, FBtnBikePick.EffectiveWidth - FBtnBikePick.Border.Right - 46) * FBtnBikePick.UIScale) + '  v';
  if FBtnSizePick <> nil then
    FBtnSizePick.Caption := CurrentSizeCaption + '  v';
  if FLblPose <> nil then
    FLblPose.Caption := Format(UiText('Pose: %s  (%d/%d)'),
      [PoseName, FSelPose + 1, Max(1, FPoseNames.Count)]);
  if FLblCadence <> nil then
    FLblCadence.Caption := Format(UiText('%d rpm'), [Round(FCadenceRpm)]);
  if FLblSeatH <> nil then
    FLblSeatH.Caption := Format(UiText('%.0f mm'), [FFitSeatExt]);
  if FLblSeatO <> nil then
  begin
    if FFitSaddleOff > 0.5 then
      FLblSeatO.Caption := '+' + IntToStr(Round(FFitSaddleOff)) + UiText(' mm')
    else
      FLblSeatO.Caption := IntToStr(Round(FFitSaddleOff)) + UiText(' mm');
  end;
  if FLblSpacers <> nil then
    FLblSpacers.Caption := Format(UiText('%.0f mm'), [FFitSpacers]);
  if FLblStem <> nil then
    FLblStem.Caption := Format(UiText('%.0f mm'), [FFitStem]);
  if FLblHeight <> nil then
    FLblHeight.Caption := Format(UiText('%.0f cm'), [FFitHeightCm]);
  if FLblInseam <> nil then
    FLblInseam.Caption := Format(UiText('%.0f cm'), [FFitInseamCm]);
  if FLblBulk <> nil then
  begin
    if FFitBulk > 0 then
      FLblBulk.Caption := '+' + IntToStr(Round(FFitBulk * 100)) + '%'
    else
      FLblBulk.Caption := IntToStr(Round(FFitBulk * 100)) + '%';
  end;
  if FLblBelly <> nil then
  begin
    if FFitBelly > 0 then
      FLblBelly.Caption := '+' + IntToStr(Round(FFitBelly * 100)) + '%'
    else
      FLblBelly.Caption := IntToStr(Round(FFitBelly * 100)) + '%';
  end;
  if FLblKnee <> nil then
  begin
    if Abs(FFitKneeFlare) < 0.005 then
      FLblKnee.Caption := '0'
    else if FFitKneeFlare > 0 then
      FLblKnee.Caption := '+' + Format('%.2f', [FFitKneeFlare])
    else
      FLblKnee.Caption := Format('%.2f', [FFitKneeFlare]);
  end;
  if FLblAnkle <> nil then
    FLblAnkle.Caption := IntToStr(Round(FFitAnkleFlex)) + '°';
  for I:=0 to High(FValueButtons)do if(FValueButtons[I]<>nil)and(FValueLabels[I]<>nil)then
    FValueButtons[I].Caption:=FValueLabels[I].Caption;
  UpdateReachStackOverlay;
  if FLblResultInfo <> nil then
    FLblResultInfo.Caption := Format(UiText('%d rpm'), [Round(FCadenceRpm)]);
  if FLiveRide and (FLblPose <> nil) then
    BindUiText(FLblPose, 'Ride pose and animation');
  if FLabelStatus <> nil then
    BindUiText(FLabelStatus, 'Changes saved automatically');
  if FLiveRide and (FLabelStatus <> nil) then
    BindUiText(FLabelStatus, 'Changes apply to the rider in the current ride');
end;

{ ═══════════════════════ color strip (верхний оверлей панели результата) ══ }

const
  DyeSlotCaption: array[0..9] of string = (
    'Jersey', 'Bib shorts', 'Socks', 'Shoes', 'Gloves', 'Skin', 'Hair', 'Frame', 'Rims', 'Helmet');
  { 0..6 = TClothSlot, 7 = рама, 8 = ободы, 9 = шлем (индексы 7/8 — как в
    сохранённых настройках, не менять!) }
  DyeIdxFrame  = 7;
  DyeIdxRim    = 8;
  DyeIdxHelmet = 9;

procedure TBikeFitPage.BuildColorStrip;
var
  I: Integer;
  B: TCastleButton;
  Lbl: TCastleLabel;
begin
  FDyeStrip := TCastleRectangleControl.Create(FUiOwner);
  FDyeStrip.Color := Vector4(0.05, 0.08, 0.07, 0.85);
  FDyeStrip.Width := 54 + 10 * 48 + 6;
  FDyeStrip.Height := 50;
  FDyeStrip.Anchor(hpMiddle, 0);
  FDyeStrip.Anchor(vpTop, -94);
  FColParams.InsertFront(FDyeStrip);

  Lbl := TMenuLabel.Create(FUiOwner);
  BindUiText(Lbl, 'Color');
  Lbl.Color := MenuText;
  Lbl.FontScale := 0.7;
  Lbl.Anchor(hpLeft, 6);
  Lbl.Anchor(vpTop, -8);
  FDyeStrip.InsertFront(Lbl);

  for I := 0 to 9 do
  begin
    B := TMenuButton.Create(FUiOwner);
    BindUiText(B, DyeSlotCaption[I]);
    B.FontScale := 0.85;
    TMenuButton(B).AutoIcon := False;
    B.AutoSize := False;
    B.Width := 44;
    B.Height := 42;
    B.CustomBackground := True;
    B.Tag := I;
    B.OnClick := @ClickDyeSlot;
    B.Anchor(hpLeft, 54 + I * 48);
    B.Anchor(vpMiddle, 0);
    FDyeStrip.InsertFront(B);
    FDyeBtns[I] := B;
  end;

  { попап палитры: [0] = «выкл», дальше 12 swatch'ей сеткой 7×2 }
  FDyePop := TCastleRectangleControl.Create(FUiOwner);
  FDyePop.Color := Vector4(0.08, 0.11, 0.10, 0.98);
  FDyePop.Width := 7 * 44 + 12;
  FDyePop.Height := 2 * 44 + 44;
  FDyePop.Anchor(hpMiddle);
  FDyePop.Anchor(vpTop, -90);
  FDyePop.Exists := False;
  FColResult.InsertFront(FDyePop);
  FDyeTitle:=TMenuLabel.Create(FUiOwner);FDyeTitle.Color:=White;
  FDyeTitle.FontSize:=18;FDyeTitle.Anchor(hpLeft,8);FDyeTitle.Anchor(vpTop,-6);
  FDyePop.InsertFront(FDyeTitle);
  for I := 0 to 12 do
  begin
    B := TMenuButton.Create(FUiOwner);
    B.AutoSize := False;
    B.Width := 40;
    B.Height := 40;
    B.CustomBackground := True;
    B.Tag := I;
    B.OnClick := @ClickDyeSw;
    B.Anchor(hpLeft, 6 + (I mod 7) * 44);
    B.Anchor(vpTop, -36 - (I div 7) * 44);
    FDyePop.InsertFront(B);
    FDyePopSw[I] := B;
  end;

  UpdateDyeStripVisuals;
end;

procedure TBikeFitPage.CloseDyePopup;
begin
  FDyePopSlot := -1;
  if FDyePop <> nil then FDyePop.Exists := False;
end;

procedure TBikeFitPage.FillDyePopup(AIdx: Integer);

  function Pal(I: Integer): TVector4;
  begin
    { [0] — служебный («выкл»); палитра с индекса 1.
      Одежда/байк — яркие, кожа — только тона кожи, волосы — натуральные. }
    if AIdx = Ord(csSkin) then
      case I of
        1:  Result := Vector4(255/255, 224/255, 207/255, 1);
        2:  Result := Vector4(248/255, 213/255, 190/255, 1);
        3:  Result := Vector4(242/255, 202/255, 175/255, 1);
        4:  Result := Vector4(236/255, 190/255, 158/255, 1);
        5:  Result := Vector4(228/255, 176/255, 142/255, 1);
        6:  Result := Vector4(217/255, 161/255, 124/255, 1);
        7:  Result := Vector4(204/255, 145/255, 108/255, 1);
        8:  Result := Vector4(190/255, 128/255,  92/255, 1);
        9:  Result := Vector4(172/255, 110/255,  77/255, 1);
        10: Result := Vector4(150/255,  92/255,  63/255, 1);
        11: Result := Vector4(124/255,  74/255,  50/255, 1);
      else
        Result := Vector4(98/255, 58/255, 38/255, 1);
      end
    else if AIdx = Ord(csHair) then
      case I of
        1:  Result := Vector4(240/255, 230/255, 210/255, 1); { платиновый }
        2:  Result := Vector4(230/255, 200/255, 140/255, 1); { блонд }
        3:  Result := Vector4(190/255, 150/255,  95/255, 1); { тёмный блонд }
        4:  Result := Vector4(150/255, 105/255,  60/255, 1); { русый }
        5:  Result := Vector4(110/255,  70/255,  40/255, 1); { каштановый }
        6:  Result := Vector4( 70/255,  45/255,  25/255, 1); { тёмный шатен }
        7:  Result := Vector4( 25/255,  20/255,  18/255, 1); { чёрный }
        8:  Result := Vector4(190/255,  90/255,  40/255, 1); { медный }
        9:  Result := Vector4(130/255,  50/255,  30/255, 1); { красно-коричневый }
        10: Result := Vector4(170/255,  60/255,  35/255, 1); { рыжий }
        11: Result := Vector4(160/255, 160/255, 160/255, 1); { седой }
      else
        Result := Vector4(215/255, 215/255, 220/255, 1);     { серебристый }
      end
    else
      case I of
        1:  Result := Vector4(1, 1, 1, 1);
        2:  Result := Vector4(220/255,  40/255,  40/255, 1);
        3:  Result := Vector4( 20/255,  50/255, 140/255, 1);
        4:  Result := Vector4( 30/255, 120/255, 210/255, 1);
        5:  Result := Vector4(240/255, 210/255,  40/255, 1);
        6:  Result := Vector4(230/255,  90/255, 160/255, 1);
        7:  Result := Vector4( 50/255, 170/255,  70/255, 1);
        8:  Result := Vector4(150/255,  90/255, 210/255, 1);
        9:  Result := Vector4(240/255, 140/255,  40/255, 1);
        10: Result := Vector4( 30/255,  30/255,  30/255, 1);
        11: Result := Vector4( 90/255,  90/255,  90/255, 1);
      else
        Result := Vector4(40/255, 180/255, 180/255, 1);
      end;
  end;

var
  I: Integer;
  C: TVector4;
begin
  if FDyePop = nil then Exit;
  FDyePopSlot := AIdx;
  for I := 0 to 12 do
  begin
    if I = 0 then
    begin
      FDyePopSw[I].Caption := '—';
      FDyePopSw[I].FontScale := 0.8;
      C := Vector4(0.16, 0.16, 0.18, 1);
    end
    else
    begin
      FDyePopSw[I].Caption := '';
      C := Pal(I);
    end;
    FDyePopSw[I].CustomColorNormal := C;
    FDyePopSw[I].CustomColorFocused := C;
    FDyePopSw[I].CustomColorPressed := C;
  end;
  FDyePop.Exists := True;
end;

procedure TBikeFitPage.ClickDyeSlot(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := TCastleButton(Sender).Tag;
  FDyeTitle.Caption:=UiText(DyeSlotCaption[Idx]);
  if FDyePopSlot = Idx then
    CloseDyePopup
  else
    FillDyePopup(Idx);
end;

procedure TBikeFitPage.ClickDyeSw(Sender: TObject);var
  Sw: Integer;
  C4: TVector4;
  C: TVector3;
begin
  if FDyePopSlot < 0 then Exit;
  Sw := TCastleButton(Sender).Tag;
  if Sw = 0 then
    C := Vector3(0, 0, 0)   { «выкл» — цвет игнорируется }
  else
  begin
    C4 := TCastleButton(Sender).CustomColorNormal;
    C := Vector3(C4.X, C4.Y, C4.Z);
  end;
  if FDyePopSlot <= Ord(High(TClothSlot)) then
    ApplyClothSlot(TClothSlot(FDyePopSlot), C, Sw <> 0)
  else if FDyePopSlot = DyeIdxHelmet then
    ApplyHelmetColorLive(C, Sw <> 0)
  else
    ApplyBikeColorLive(FDyePopSlot = DyeIdxFrame, C, Sw <> 0);
  CloseDyePopup;
end;

procedure TBikeFitPage.UpdateDyeStripVisuals;
var
  I: Integer;
  C: TVector4;
  On_: Boolean;
begin
  for I := 0 to 9 do
  begin
    if FDyeBtns[I] = nil then Continue;
    if I <= Ord(High(TClothSlot)) then
    begin
      On_ := FDyeOn[TClothSlot(I)];
      if On_ then
        C := Vector4(FDyeColor[TClothSlot(I)], 1)
      else
        C := Vector4(0.16, 0.16, 0.18, 1);
    end
    else if I = DyeIdxFrame then
    begin
      if FBikeFrameOn then C := Vector4(FBikeFrameC, 1)
                      else C := Vector4(0.16, 0.16, 0.18, 1);
    end
    else if I = DyeIdxRim then
    begin
      if FBikeRimOn then C := Vector4(FBikeRimC, 1)
                    else C := Vector4(0.16, 0.16, 0.18, 1);
    end
    else
    begin
      if FHelmetOn then C := Vector4(FHelmetC, 1)
                   else C := Vector4(0.16, 0.16, 0.18, 1);
    end;
    FDyeBtns[I].CustomColorNormal := C;
    FDyeBtns[I].CustomColorFocused := C;
    FDyeBtns[I].CustomColorPressed := C;
    FDyeBtns[I].CustomTextColorUse:=True;
    if C.X*0.2126+C.Y*0.7152+C.Z*0.0722>0.55 then
      FDyeBtns[I].CustomTextColor:=Vector4(0.04,0.06,0.08,1)
    else FDyeBtns[I].CustomTextColor:=White;
  end;
end;

procedure TBikeFitPage.ApplyClothSlot(Slot: TClothSlot; const C: TVector3;
  AOn: Boolean);
begin
  FDyeColor[Slot] := C;
  FDyeOn[Slot] := AOn;
  ApplyRiderShaderDye;
  UpdateDyeStripVisuals;
  SaveBikeFitColors;
end;

procedure TBikeFitPage.ApplyRiderShaderDye;
var
  S: TClothSlot;
  R: TTripoRiderScene;
begin
  { After mount, only uniforms. RefreshShaderClothDye is load-time only. }
  if (FResultBike = nil) or (FResultBike.TripoRider = nil) then Exit;
  R := FResultBike.TripoRider;
  if R.ClothDyeMode <> cdmShader then Exit;
  for S := Low(TClothSlot) to High(TClothSlot) do
    if FDyeOn[S] then
      R.SetClothColor(S, FDyeColor[S])
    else
      R.ClearClothColor(S);
end;

procedure TBikeFitPage.ApplyBikeColorLive(AFrame: Boolean; const C: TVector3;
  AOn: Boolean);
begin
  if AFrame then
  begin
    FBikeFrameOn := AOn;
    if AOn then FBikeFrameC := C;
    if FResultBike <> nil then
      if AOn then
        FResultBike.SetFrameColorLive(C)
      else
        FResultBike.SetFrameColorLive(FOrigFrameC);
  end
  else
  begin
    FBikeRimOn := AOn;
    if AOn then FBikeRimC := C;
    if FResultBike <> nil then
      if AOn then
        FResultBike.SetRimColorLive(C)
      else
        FResultBike.SetRimColorLive(FOrigRimC);
  end;
  UpdateDyeStripVisuals;
  SaveBikeFitColors;
end;

{ Шлем: live-tint материалов (BaseColor × фактор, оригиналы кэшированы в
  райдере) — без перезагрузки, но tint живёт в инстансе райдера, поэтому
  после подмены/пересборки его надо повторить (ReapplyHelmetColor). }
procedure TBikeFitPage.ApplyHelmetColorLive(const C: TVector3; AOn: Boolean);
begin
  FHelmetOn := AOn;
  if AOn then FHelmetC := C;
  ReapplyHelmetColor;
  UpdateDyeStripVisuals;
  SaveBikeFitColors;
end;

procedure TBikeFitPage.ReapplyHelmetColor;
begin
  if (FResultBike = nil) or (FResultBike.TripoRider = nil) then Exit;
  if FHelmetOn then
    FResultBike.TripoRider.ApplyHelmetColor(FHelmetC, True)
  else
    FResultBike.TripoRider.ApplyHelmetColor(Vector3(1, 1, 1), False);
end;

procedure TBikeFitPage.ReapplyColorsAfterBuild;
begin
  if FResultBike = nil then Exit;
  FOrigFrameC := FResultBike.LastBuildColors.Frame;
  FOrigRimC := FResultBike.LastBuildColors.Rim;
  if FBikeFrameOn then FResultBike.SetFrameColorLive(FBikeFrameC);
  if FBikeRimOn then FResultBike.SetRimColorLive(FBikeRimC);
  ApplyRiderShaderDye;
  ReapplyHelmetColor;
end;

procedure TBikeFitPage.SaveBikeFitColors;

  function HexOf(const C: TVector3): string;
  begin
    Result := IntToHex(EnsureRange(Round(C.X * 255), 0, 255), 2) +
              IntToHex(EnsureRange(Round(C.Y * 255), 0, 255), 2) +
              IntToHex(EnsureRange(Round(C.Z * 255), 0, 255), 2);
  end;

var
  SL: TStringList;
  S: TClothSlot;
begin
  SL := TStringList.Create;
  try
    SL.StrictDelimiter := True;
    SL.Delimiter := ',';
    for S := Low(TClothSlot) to High(TClothSlot) do
      if FDyeOn[S] then SL.Add(HexOf(FDyeColor[S])) else SL.Add('');
    if FBikeFrameOn then SL.Add(HexOf(FBikeFrameC)) else SL.Add('');
    if FBikeRimOn then SL.Add(HexOf(FBikeRimC)) else SL.Add('');
    if FHelmetOn then SL.Add(HexOf(FHelmetC)) else SL.Add('');
    Settings.BikeFitColors := SL.DelimitedText;
  finally
    SL.Free;
  end;
end;

procedure TBikeFitPage.LoadBikeFitColors;

  function VecOf(const H: string; out C: TVector3): Boolean;
  var
    V: Integer;
  begin
    Result := (Length(H) = 6) and TryStrToInt('$' + H, V);
    if Result then
      C := Vector3(((V shr 16) and $FF) / 255.0,
                   ((V shr 8) and $FF) / 255.0,
                   (V and $FF) / 255.0);
  end;

var
  SL: TStringList;
  S: TClothSlot;
  I: Integer;
  C: TVector3;
begin
  for S := Low(TClothSlot) to High(TClothSlot) do FDyeOn[S] := False;
  FBikeFrameOn := False;
  FBikeRimOn := False;
  FHelmetOn := False;
  SL := TStringList.Create;
  try
    SL.StrictDelimiter := True;
    SL.Delimiter := ',';
    SL.DelimitedText := Settings.BikeFitColors;
    for S := Low(TClothSlot) to High(TClothSlot) do
    begin
      I := Ord(S);
      if (I < SL.Count) and VecOf(SL[I], C) then
      begin
        FDyeColor[S] := C;
        FDyeOn[S] := True;
      end;
    end;
    if (SL.Count > 7) and VecOf(SL[7], C) then
    begin
      FBikeFrameC := C;
      FBikeFrameOn := True;
    end;
    if (SL.Count > 8) and VecOf(SL[8], C) then
    begin
      FBikeRimC := C;
      FBikeRimOn := True;
    end;
    if (SL.Count > 9) and VecOf(SL[9], C) then
    begin
      FHelmetC := C;
      FHelmetOn := True;
    end;
  finally
    SL.Free;
  end;
  UpdateDyeStripVisuals;
end;

procedure TBikeFitPage.McpSetColor(const ASlot: string; const C: TVector3;
  AOn: Boolean);
var
  Slot: TClothSlot;
begin
  if SameText(ASlot, 'frame') then
    ApplyBikeColorLive(True, C, AOn)
  else if SameText(ASlot, 'rim') then
    ApplyBikeColorLive(False, C, AOn)
  else if SameText(ASlot, 'helmet') then
    ApplyHelmetColorLive(C, AOn)
  else if ClothSlotOfName(ASlot, Slot) then
    ApplyClothSlot(Slot, C, AOn)
  else
    raise Exception.Create('unknown color slot: ' + ASlot);
end;

procedure TBikeFitPage.Resize;
begin
  inherited;
  LayoutSections;
  if FLabelStatus <> nil then FLabelStatus.MaxWidth := Max(100, EffectiveWidth - 32);
  if FBtnBikePick <> nil then UpdateLabels;
end;

procedure TBikeFitPage.ClickSection(Sender:TObject);
begin
  FSection:=(Sender as TMenuButton).Tag;ClosePopup;CloseDyePopup;LayoutSections;
end;

function TBikeFitPage.HandleBack:Boolean;
begin
  Result:=True;
  if FValuePopup<>nil then begin CancelValue(nil);Exit;end;
  if(FDyePop<>nil)and FDyePop.Exists then begin CloseDyePopup;Exit;end;
  if(FPopupOverlay<>nil)and FPopupOverlay.Exists then begin ClosePopup;Exit;end;
  Result:=False;
end;

procedure TBikeFitPage.LayoutSections;
var S,W,TabW:Single;I:Integer;
  procedure Row(B:TCastleButton;Section,Index:Integer;Top:Single);
  var C:TCastleUserInterface;J:Integer;
  begin
    if B=nil then Exit;C:=B.Parent;C.Exists:=FSection=Section;
    C.Anchor(vpTop,-(Top+Index*38)/S);C.Height:=34/S;
    for J:=0 to C.ControlsCount-1 do
      if C.Controls[J] is TCastleLabel then begin
        TCastleLabel(C.Controls[J]).FontScale:=1;TCastleLabel(C.Controls[J]).FontSize:=14/S;
        if TCastleLabel(C.Controls[J]).HorizontalAnchorSelf=hpRight then
          C.Controls[J].Anchor(hpRight,-40/S);
      end else if C.Controls[J] is TCastleButton then begin
        TCastleButton(C.Controls[J]).FontScale:=1;TCastleButton(C.Controls[J]).FontSize:=18/S;
        C.Controls[J].Width:=34/S;C.Controls[J].Height:=28/S;
        if C.Controls[J]=B then C.Controls[J].Anchor(hpRight,-118/S);
      end;
  end;
begin
  if(FSectionButtons[2]=nil)or(FDyeStrip=nil)or(FBottomRow.EffectiveWidth<=0)then Exit;
  S:=Max(0.65,Min(1,UIScale));W:=Min(420/S,FBottomRow.EffectiveWidth*0.46);
  if FMainHost<>nil then FMainHost.Border.Bottom:=42/S;
  if FLabelStatus<>nil then begin
    FLabelStatus.CustomFont:=MenuFont;FLabelStatus.FontScale:=1;
    FLabelStatus.FontSize:=12/S;FLabelStatus.Color:=MenuMuted;
    FLabelStatus.Anchor(vpBottom,12/S);
  end;
  FColParams.WidthFraction:=0;FColParams.Width:=W;
  if FLblPose<>nil then begin
    FLblPose.FontScale:=1;FLblPose.FontSize:=13/S;FLblPose.Anchor(vpBottom,8/S);
  end;
  if FPosePrev<>nil then begin
    FPosePrev.FontScale:=1;FPosePrev.FontSize:=16/S;FPosePrev.Width:=34/S;FPosePrev.Height:=30/S;
    FPoseNext.FontScale:=1;FPoseNext.FontSize:=16/S;FPoseNext.Width:=34/S;FPoseNext.Height:=30/S;
    FPoseToggle.FontScale:=1;FPoseToggle.FontSize:=14/S;FPoseToggle.Height:=30/S;
    FPosePrev.Anchor(hpLeft,12/S);FPoseNext.Anchor(hpLeft,52/S);FPoseToggle.Anchor(hpLeft,92/S);
    FPosePrev.Anchor(vpBottom,38/S);FPoseNext.Anchor(vpBottom,38/S);FPoseToggle.Anchor(vpBottom,38/S);
  end;
  FColResult.WidthFraction:=0;FColResult.Width:=FBottomRow.EffectiveWidth-W;
  TabW:=(W-32)/3;
  for I:=0 to High(FSectionButtons)do begin
    FSectionButtons[I].Width:=TabW;FSectionButtons[I].Height:=34/S;
    FSectionButtons[I].FontSize:=14/S;
    FSectionButtons[I].Anchor(hpLeft,8+I*(TabW+8));FSectionButtons[I].Anchor(vpTop,-44/S);
    SelectMenuButton(FSectionButtons[I],FSection=I);
  end;
  FBikeControls.Exists:=FSection=0;FBikeControls.Anchor(vpTop,-92/S);
  FBikeControls.Height:=78/S;
  FBtnBikePick.Parent.Height:=36/S;
  FBtnBikePick.Height:=32/S;FBtnBikePick.FontScale:=1;FBtnBikePick.FontSize:=14/S;
  FBtnBikePick.Border.Right:=78/S;
  FBtnSizePick.Height:=32/S;FBtnSizePick.Width:=65/S;FBtnSizePick.FontScale:=1;FBtnSizePick.FontSize:=14/S;
  Row(FBtnSeatHDown,0,0,182);Row(FBtnSeatODown,0,1,182);
  Row(FBtnSpacersDown,0,2,182);Row(FBtnStemDown,0,3,182);
  Row(FBtnHeightDown,1,0,100);Row(FBtnInseamDown,1,1,100);
  Row(FBtnBulkDown,1,2,100);Row(FBtnBellyDown,1,3,100);
  Row(FBtnKneeDown,1,4,100);Row(FBtnAnkleDown,1,5,100);
  for I:=0 to High(FValueButtons)do if FValueButtons[I]<>nil then begin
    FValueButtons[I].Width:=74/S;FValueButtons[I].Height:=28/S;FValueButtons[I].FontScale:=1;
    FValueButtons[I].FontSize:=14/S;FValueButtons[I].Anchor(hpRight,-38/S);
  end;
  FRiderParams.Width:=200/S;FRiderParams.Height:=32/S;FRiderParams.FontScale:=1;FRiderParams.FontSize:=14/S;
  FRiderParams.Exists:=FSection=1;FRiderParams.Anchor(vpBottom,105/S);
  FCadenceControls.Anchor(vpBottom,8);FCadenceControls.Height:=86/S;
  if FCadenceCaption<>nil then begin FCadenceCaption.FontScale:=1;FCadenceCaption.FontSize:=14/S;end;
  FBtnCadenceDown.Width:=34/S;FBtnCadenceDown.Height:=28/S;
  FBtnCadenceUp.Width:=34/S;FBtnCadenceUp.Height:=28/S;
  FBtnCadenceDown.FontScale:=1;FBtnCadenceDown.FontSize:=18/S;
  FBtnCadenceUp.FontScale:=1;FBtnCadenceUp.FontSize:=18/S;
  FLblCadence.FontScale:=1;FLblCadence.FontSize:=16/S;
  FDyeStrip.Exists:=FSection=2;FDyeStrip.Width:=W-20;FDyeStrip.Height:=266/S;
  FDyeStrip.Anchor(vpTop,-94/S);
  for I:=0 to High(FDyeBtns)do begin
    FDyeBtns[I].Width:=(W-40)/2;FDyeBtns[I].Height:=40/S;
    FDyeBtns[I].FontScale:=1;FDyeBtns[I].FontSize:=14/S;
    FDyeBtns[I].Anchor(hpLeft,6+(I mod 2)*(W-28)/2);
    FDyeBtns[I].Anchor(vpTop,-(34+(I div 2)*44)/S);
  end;
end;

procedure TBikeFitPage.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited;
  if (not Exists) or FLoadingPreview then Exit;

  FLoadingPreview := True;
  try
    PumpResultRiderLoad;
    if FDirtyResult then ReloadResultPreview;
  finally
    FLoadingPreview := False;
    if FReleasePreviewPending then
    begin
      FReleasePreviewPending := False;
      PageHidden;
    end;
  end;
  if not Exists then Exit;
  if FLiveSettingsDirty then begin
    FFitSaveDelay:=FFitSaveDelay-SecondsPassed;
    if FFitSaveDelay<=0 then begin FFitSaveDelay:=5;ClickApply(nil);end;
  end;
  if FPosePrev<>nil then begin FPosePrev.Exists:=not FLiveRide;FPoseNext.Exists:=not FLiveRide;FPoseToggle.Exists:=not FLiveRide;end;
  if FLiveRide then
  begin
    if Round(FCadenceRpm) <> Round(ViewPlay.RideCadence) then
    begin
      FCadenceRpm := ViewPlay.RideCadence;
      UpdateLabels;
    end;
    Exit;
  end;
  if FResultBike <> nil then
  begin
    FResultBike.AnimateFrame(SecondsPassed);
    if FPoseAuto and(FPoseNames.Count > 1)then
    begin
      FPoseTimer := FPoseTimer + SecondsPassed;
      if FPoseTimer >= FPoseCycleSec then
      begin
        FPoseTimer := 0;
        AdvancePoseCycle;
      end;
    end;
  end;
end;

procedure TBikeFitPage.ClickCadenceDown(Sender: TObject);
begin
  FCadenceRpm := Max(0, FCadenceRpm - 10);
  ApplyCadenceToResult;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickCadenceUp(Sender: TObject);
begin
  FCadenceRpm := Min(160, FCadenceRpm + 10);
  ApplyCadenceToResult;
  UpdateLabels;
end;

procedure TBikeFitPage.NudgeFit(var AValue: Single; ADelta, AMin, AMax: Single);
begin
  AValue := EnsureRange(AValue + ADelta, AMin, AMax);
  FFitInited := True;
  ApplyFitToPreview;
  ApplyCadenceToResult;
  UpdateLabels;
end;

procedure TBikeFitPage.SyncFitFromBikeIfNeeded;
var
  SeatExt, Off, Spacers, Stem: Single;
begin
  if FFitInited then Exit;
  ReadFitAdjustments(FResultBike, SeatExt, Off, Spacers, Stem);
  FFitSeatExt := SeatExt;
  FFitSaddleOff := Off;
  FFitSpacers := Spacers;
  FFitStem := Stem;
  FFitInited := True;
end;

procedure TBikeFitPage.ApplyFitToPreview;
begin
  if FResultBike = nil then Exit;
  ApplyFitAdjustments(FResultBike, FFitSeatExt, FFitSaddleOff,
    FFitSpacers, FFitStem);
  ApplyRiderShapeToPreview;
  ApplyKneeAnkleToPreview;
end;

procedure TBikeFitPage.SeedRiderShapeFromBike;
var
  RestH, RestI, NatH, NatI: Single;
  NewModel, Keep: Boolean;
begin
  if FResultBike = nil then Exit;
  if FResultBike.TripoRider = nil then Exit;
  RestH := FResultBike.TripoRider.RestHeight;
  RestI := FResultBike.TripoRider.StableLegReach;
  if RestH < 0.5 then RestH := 1.75;
  if RestI < 0.4 then RestI := 0.80;
  NatH := Round(RestH * 100);
  NatI := Round(RestI * 100);
  if NatI < 60 then NatI := 80;
  if NatI > 100 then NatI := 85;
  Keep := FSeededRestH < -0.5;
  NewModel := (FSeededRestH >= 0) and (Abs(RestH - FSeededRestH) > 0.04);
  { Keep settings height on the first rider. Switching models reseeds native. }
  if (not Keep) and ((FFitHeightCm < 80) or (FFitHeightCm > 230)
       or (FSeededRestH < 0.15) or NewModel) then
  begin
    FFitHeightCm := NatH;
    if (FFitInseamCm < 55) or (FFitInseamCm > 105)
       or (FSeededRestH < 0.15) or NewModel then
      FFitInseamCm := NatI;
  end;
  FSeededRestH := RestH;
end;

procedure TBikeFitPage.ApplyRiderShapeToPreview;
begin
  if FResultBike = nil then Exit;
  SeedRiderShapeFromBike;
  ApplyRiderShapeAdjustments(FResultBike,
    FFitHeightCm, FFitInseamCm, FFitBulk, FFitBelly);
  LiveFitChanged;
end;

procedure TBikeFitPage.ApplyKneeAnkleToPreview;
begin
  if FResultBike = nil then Exit;
  ApplyFitKneeAnkle(FResultBike, FFitKneeFlare, FFitAnkleFlex);
  LiveFitChanged;
end;

procedure TBikeFitPage.UpdateReachStackOverlay;
var
  StackMm, ReachMm: Single;
begin
  ReadFrameStackReach(FResultBike, StackMm, ReachMm);
  if FLblReach <> nil then
  begin
    if ReachMm > 0 then
      FLblReach.Caption := Format(UiText('Reach  %.0f mm'), [ReachMm])
    else
      BindUiText(FLblReach, 'Reach  —');
  end;
  if FLblStack <> nil then
  begin
    if StackMm > 0 then
      FLblStack.Caption := Format(UiText('Stack  %.0f mm'), [StackMm])
    else
      BindUiText(FLblStack, 'Stack  —');
  end;
end;

procedure TBikeFitPage.ClickSeatHDown(Sender: TObject);
begin
  NudgeFit(FFitSeatExt, -5, 20, 280);
end;

procedure TBikeFitPage.ClickSeatHUp(Sender: TObject);
begin
  NudgeFit(FFitSeatExt, 5, 20, 280);
end;

procedure TBikeFitPage.ClickSeatODown(Sender: TObject);
begin
  NudgeFit(FFitSaddleOff, -5, -50, 50);
end;

procedure TBikeFitPage.ClickSeatOUp(Sender: TObject);
begin
  NudgeFit(FFitSaddleOff, 5, -50, 50);
end;

procedure TBikeFitPage.ClickSpacersDown(Sender: TObject);
begin
  NudgeFit(FFitSpacers, -5, 0, 50);
end;

procedure TBikeFitPage.ClickSpacersUp(Sender: TObject);
begin
  NudgeFit(FFitSpacers, 5, 0, 50);
end;

procedure TBikeFitPage.ClickStemDown(Sender: TObject);
begin
  NudgeFit(FFitStem, -10, 60, 140);
end;

procedure TBikeFitPage.ClickStemUp(Sender: TObject);
begin
  NudgeFit(FFitStem, 10, 60, 140);
end;

procedure TBikeFitPage.ClickHeightDown(Sender: TObject);
begin
  SeedRiderShapeFromBike;
  FFitHeightCm := EnsureRange(FFitHeightCm - 1, 80, 230);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickHeightUp(Sender: TObject);
begin
  SeedRiderShapeFromBike;
  FFitHeightCm := EnsureRange(FFitHeightCm + 1, 80, 230);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickInseamDown(Sender: TObject);
begin
  SeedRiderShapeFromBike;
  FFitInseamCm := EnsureRange(FFitInseamCm - 1, 65, 100);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickInseamUp(Sender: TObject);
begin
  SeedRiderShapeFromBike;
  FFitInseamCm := EnsureRange(FFitInseamCm + 1, 65, 100);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickBulkDown(Sender: TObject);
begin
  FFitBulk := EnsureRange(FFitBulk - 0.02, -0.12, 0.30);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickBulkUp(Sender: TObject);
begin
  FFitBulk := EnsureRange(FFitBulk + 0.02, -0.12, 0.30);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickBellyDown(Sender: TObject);
begin
  FFitBelly := EnsureRange(FFitBelly - 0.02, 0, 0.30);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickBellyUp(Sender: TObject);
begin
  FFitBelly := EnsureRange(FFitBelly + 0.02, 0, 0.30);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickKneeDown(Sender: TObject);
begin
  FFitKneeFlare := EnsureRange(FFitKneeFlare - 0.05, -0.50, 0.50);
  FFitInited := True;
  ApplyKneeAnkleToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickKneeUp(Sender: TObject);
begin
  FFitKneeFlare := EnsureRange(FFitKneeFlare + 0.05, -0.50, 0.50);
  FFitInited := True;
  ApplyKneeAnkleToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickAnkleDown(Sender: TObject);
begin
  FFitAnkleFlex := EnsureRange(FFitAnkleFlex - 2, 0, 40);
  FFitInited := True;
  ApplyKneeAnkleToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickAnkleUp(Sender: TObject);
begin
  FFitAnkleFlex := EnsureRange(FFitAnkleFlex + 2, 0, 40);
  FFitInited := True;
  ApplyKneeAnkleToPreview;
  UpdateLabels;
end;

function TBikeFitPage.RiderCount: Integer;
begin
  Result := 2;
end;

procedure TBikeFitPage.McpSelectRider(AIndex: Integer);
var
  G: string;
begin
  if AIndex <= 0 then
    G := 'male'
  else
    G := 'female';
  Settings.SetGender(G);
  if FResultBike <> nil then
    RequestResultRider(CurrentRiderPath)
  else
    FDirtyResult := True;
  UpdateLabels;
end;

procedure TBikeFitPage.McpNudge(const AParam: string; ASteps: Integer);
var
  I, N: Integer;
  Up: Boolean;
  P: string;
begin
  N := Abs(ASteps);
  if N < 1 then N := 1;
  Up := ASteps >= 0;
  P := LowerCase(Trim(AParam));
  for I := 1 to N do
  begin
    if (P = 'height') or (P = 'рост') then
      if Up then ClickHeightUp(nil) else ClickHeightDown(nil)
    else if P = 'inseam' then
      if Up then ClickInseamUp(nil) else ClickInseamDown(nil)
    else if P = 'bulk' then
      if Up then ClickBulkUp(nil) else ClickBulkDown(nil)
    else if P = 'belly' then
      if Up then ClickBellyUp(nil) else ClickBellyDown(nil)
    else if (P = 'knee') or (P = 'kneeflare') or (P = 'колени') then
      if Up then ClickKneeUp(nil) else ClickKneeDown(nil)
    else if (P = 'ankle') or (P = 'feet') or (P = 'ступни') then
      if Up then ClickAnkleUp(nil) else ClickAnkleDown(nil)
    else if (P = 'seat') or (P = 'seat_h') then
      if Up then ClickSeatHUp(nil) else ClickSeatHDown(nil)
    else if (P = 'offset') or (P = 'seat_o') then
      if Up then ClickSeatOUp(nil) else ClickSeatODown(nil)
    else if P = 'spacers' then
      if Up then ClickSpacersUp(nil) else ClickSpacersDown(nil)
    else if P = 'stem' then
      if Up then ClickStemUp(nil) else ClickStemDown(nil)
    else if P = 'cadence' then
      if Up then ClickCadenceUp(nil) else ClickCadenceDown(nil)
    else
      raise Exception.Create('unknown fit param "' + AParam + '"');
  end;
end;

procedure TBikeFitPage.McpFillStatus(AResult: TJSONObject);
begin
  AResult.Add('riders', 2);
  if SameText(Settings.GetGender, 'female') then
    AResult.Add('sel_rider', 1)
  else
    AResult.Add('sel_rider', 0);
  AResult.Add('rider', CurrentRiderName);
  AResult.Add('gender', Settings.GetGender);
  AResult.Add('sel_bike', FSelBike);
  AResult.Add('bike', CurrentBikeCaption);
  AResult.Add('size', CurrentSizeCaption);
  AResult.Add('height_cm', FFitHeightCm);
  AResult.Add('inseam_cm', FFitInseamCm);
  AResult.Add('bulk', FFitBulk);
  AResult.Add('belly', FFitBelly);
  AResult.Add('knee_flare', FFitKneeFlare);
  AResult.Add('ankle_flex', FFitAnkleFlex);
  AResult.Add('seat_mm', FFitSeatExt);
  AResult.Add('offset_mm', FFitSaddleOff);
  AResult.Add('spacers_mm', FFitSpacers);
  AResult.Add('stem_mm', FFitStem);
  AResult.Add('cadence', FCadenceRpm);
  AResult.Add('has_result', FResultBike <> nil);
  AResult.Add('live_ride', FLiveRide);
  if FResultBike <> nil then AResult.Add('gpu_animation', FResultBike.GpuAnim);
  if FLiveRide then
  begin
    AResult.Add('same_bike', FResultBike = ViewPlay.Bike);
    AResult.Add('same_world', FVpResult.Items = ViewPlay.MainViewport.Items);
  end;
  if FVpResult <> nil then
  begin
    AResult.Add('camera_position', TJSONArray.Create([
      FVpResult.Camera.Translation.X, FVpResult.Camera.Translation.Y,
      FVpResult.Camera.Translation.Z]));
    AResult.Add('camera_direction', TJSONArray.Create([
      FVpResult.Camera.Direction.X, FVpResult.Camera.Direction.Y,
      FVpResult.Camera.Direction.Z]));
    AResult.Add('preview_rect', TJSONArray.Create([
      FVpResult.RenderRect.Left, FVpResult.RenderRect.Bottom,
      FVpResult.RenderRect.Width, FVpResult.RenderRect.Height]));
  end;
  if Container <> nil then
    AResult.Add('view_stack_count', Container.CurrentViewStackCount);
end;

procedure TBikeFitPage.McpLighting(AParams: TJSONObject; AResult: TJSONObject);
var
  Env, Key, Fill, RKey, RFill: Single;
  Stage: string;

  function BikeEnv: Single;
  begin
    if (FResultBike <> nil) and (FResultBike.TripoRider <> nil) then
      Result := FResultBike.RiderEnvIntensity
    else
      Result := 0.0;
  end;

  procedure SetBikeEnv(const V: Single);
  begin
    if FResultBike <> nil then
      FResultBike.RiderEnvIntensity := V;
  end;

begin
  Stage := 'read-current';
  try
    Env := BikeEnv;
    if FPrevKey <> nil then Key := FPrevKey.Intensity else Key := 0.0;
    if FPrevFill <> nil then Fill := FPrevFill.Intensity else Fill := 0.0;
    if (FResultBike <> nil) and (FResultBike.TripoRider <> nil) then
    begin
      RKey := FResultBike.RiderKeyIntensity;
      RFill := FResultBike.RiderFillIntensity;
    end else
    begin
      RKey := 0.0;
      RFill := 0.0;
    end;

    Stage := 'parse';
    if AParams.Find('env') <> nil then
      Env := AParams.Get('env', 0.0);
    if AParams.Find('key') <> nil then
      Key := AParams.Get('key', 0.0);
    if AParams.Find('fill') <> nil then
      Fill := AParams.Get('fill', 0.0);
    if AParams.Find('rkey') <> nil then
      RKey := AParams.Get('rkey', 0.0);
    if AParams.Find('rfill') <> nil then
      RFill := AParams.Get('rfill', 0.0);

    Stage := 'apply';
    SetBikeEnv(Env);
    if FPrevKey <> nil then FPrevKey.Intensity := Key;
    if FPrevFill <> nil then FPrevFill.Intensity := Fill;
    if (FResultBike <> nil) and (FResultBike.TripoRider <> nil) then
    begin
      FResultBike.RiderKeyIntensity := RKey;
      FResultBike.RiderFillIntensity := RFill;
    end;

    Stage := 'echo';
    AResult.Add('env', BikeEnv);
    AResult.Add('key', Key);
    AResult.Add('fill', Fill);
    AResult.Add('rkey', RKey);
    AResult.Add('rfill', RFill);
    if (FResultBike <> nil) and (FResultBike.TripoRider <> nil) then
      AResult.Add('diag', FResultBike.TripoRider.LightDiag)
    else
      AResult.Add('diag', 'no-result-bike');
  except
    on E: Exception do
      AResult.Add('err', 'stage=' + Stage + ' ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure TBikeFitPage.ClickApply(Sender: TObject);
var
  Saved: Boolean;
begin
  Settings.BeginUpdate;
  try
    if (FSelBike >= 0) and (FSelBike < FBikePaths.Count) then
      Settings.SelectedBikeJson := FBikePaths[FSelBike]
    else
      Settings.SelectedBikeJson := '';
    Settings.SelectedBikeSize := CurrentSizeName;
    Settings.SetGender(Settings.GetGender); { refreshes MEN.glb / FEM.glb }
    Settings.SetFitAdjustments(FFitSeatExt, FFitSaddleOff, FFitSpacers, FFitStem);
    Settings.SetRiderShape(FFitHeightCm, FFitInseamCm, FFitBulk, FFitBelly,
      FFitKneeFlare, FFitAnkleFlex);
  finally
    Saved := Settings.EndUpdate;
  end;
  if not Saved then
  begin
    BindUiText(FLabelStatus, 'Could not save settings. Please try again.');
    Exit;
  end;
  FLiveSettingsDirty := False;
  if FLiveRide then
    BindUiText(FLabelStatus, 'Saved and applied to the current ride.')
  else
    BindUiText(FLabelStatus, 'Saved — applies to the next ride.');
  Logger.Info(Format('[BikeFit] apply bike=%s size=%s rider=%s fit seat=%.0f off=%.0f sp=%.0f stem=%.0f h=%.0f in=%.0f bulk=%.2f belly=%.2f knee=%.2f ankle=%.0f',
    [Settings.SelectedBikeJson, Settings.SelectedBikeSize,
     Settings.SelectedRiderGlb, FFitSeatExt, FFitSaddleOff, FFitSpacers, FFitStem,
     FFitHeightCm, FFitInseamCm, FFitBulk, FFitBelly,
     FFitKneeFlare, FFitAnkleFlex]));
end;

procedure TBikeFitPage.ClickPose(Sender:TObject);
begin
  if FLiveRide or(FPoseNames.Count=0)then Exit;
  if TComponent(Sender).Tag=0 then FPoseAuto:=not FPoseAuto
  else begin
    FPoseAuto:=False;FSelPose:=(FSelPose+TComponent(Sender).Tag+FPoseNames.Count)mod FPoseNames.Count;
    FPoseTimer:=0;ApplyResultPose;UpdateLabels;
  end;
  SelectMenuButton(FPoseToggle,FPoseAuto);
end;
procedure TBikeFitPage.ClickRiderParams(Sender:TObject);
begin ViewMenu.OpenTab('rider');end;

procedure TBikeFitPage.CancelValue(Sender:TObject);
var Old:TCastleRectangleControl;
begin
  FValueEdit:=nil;Old:=FValuePopup;FValuePopup:=nil;
  if Old<>nil then begin Old.Exists:=False;RemoveControl(Old);ApplicationProperties.FreeDelayed(Old);end;
end;
procedure TBikeFitPage.ClickValue(Sender:TObject);
var B:TCastleButton;V:Single;FS:TFormatSettings;
begin
  CancelValue(nil);FValueIndex:=TComponent(Sender).Tag;
  case FValueIndex of
    0:V:=FFitSeatExt;1:V:=FFitSaddleOff;2:V:=FFitSpacers;3:V:=FFitStem;
    4:V:=FFitHeightCm;5:V:=FFitInseamCm;6:V:=FFitBulk*100;7:V:=FFitBelly*100;
    8:V:=FFitKneeFlare;else V:=FFitAnkleFlex;
  end;
  FValuePopup:=TCastleRectangleControl.Create(FUiOwner);FValuePopup.Width:=320;FValuePopup.Height:=140;
  FValuePopup.Color:=Vector4(0.05,0.1,0.12,1);FValuePopup.Anchor(hpMiddle);FValuePopup.Anchor(vpMiddle);InsertFront(FValuePopup);
  FValueEdit:=TMenuEdit.Create(FValuePopup);FValueEdit.Name:='BikeFitValueInput';FValueEdit.Width:=280;FValueEdit.FontSize:=22;
  FS:=DefaultFormatSettings;FS.DecimalSeparator:='.';FValueEdit.Text:=FormatFloat('0.##',V,FS);
  FValueEdit.Anchor(hpLeft,20);FValueEdit.Anchor(vpTop,-20);FValuePopup.InsertFront(FValueEdit);
  B:=MakeNavBtn(UiText('Apply'),@ApplyValue,130,34);FUiOwner.RemoveComponent(B);FValuePopup.InsertComponent(B);B.Name:='ApplyFitValue';B.Anchor(hpLeft,20);B.Anchor(vpBottom,16);FValuePopup.InsertFront(B);
  B:=MakeNavBtn(UiText('Cancel'),@CancelValue,130,34);FUiOwner.RemoveComponent(B);FValuePopup.InsertComponent(B);B.Anchor(hpRight,-20);B.Anchor(vpBottom,16);FValuePopup.InsertFront(B);
  FValueEdit.Focused:=True;
end;
procedure TBikeFitPage.ApplyValue(Sender:TObject);
var V:Single;FS:TFormatSettings;
begin
  FS:=DefaultFormatSettings;FS.DecimalSeparator:='.';
  if not TryStrToFloat(StringReplace(Trim(FValueEdit.Text),',','.',[rfReplaceAll]),V,FS)then Exit;
  if IsNan(V)or IsInfinite(V)then Exit;
  case FValueIndex of
    0:FFitSeatExt:=EnsureRange(V,20,280);1:FFitSaddleOff:=EnsureRange(V,-50,50);
    2:FFitSpacers:=EnsureRange(V,0,50);3:FFitStem:=EnsureRange(V,60,140);
    4:FFitHeightCm:=EnsureRange(V,80,230);5:FFitInseamCm:=EnsureRange(V,65,100);
    6:FFitBulk:=EnsureRange(V/100,-0.12,0.30);7:FFitBelly:=EnsureRange(V/100,0,0.30);
    8:FFitKneeFlare:=EnsureRange(V,-0.5,0.5);9:FFitAnkleFlex:=EnsureRange(V,0,40);
  end;
  FFitInited:=True;ApplyFitToPreview;UpdateLabels;LiveFitChanged;CancelValue(nil);
end;

end.
