{ GameViewBikeFit — вкладка «Байкфит»: параметры байка и 3D-превью.

  Раскладка:
    • Слева — параметры (байк, каденс, фит).
    • Справа — результат (bike+rider): педалирование + смена поз.

  Один RIDER.glb; пропорции и форма берутся из профиля пользователя. }
unit GameViewBikeFit;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses GameRiderWardrobe, GameTravel, RiderBodyParameters, GameMenuTheme, Osm3dRiderShadow, RiderHair, RiderHeadAppearance,
  Classes, SysUtils, Math, fpjson,
  CastleComponentSerialize, CastleUIControls, CastleControls,
  CastleVectors, CastleColors, CastleURIUtils, CastleFilesUtils,
  CastleViewport, CastleScene, CastleCameras, CastleTransform,
  CastleProjection, CastleBoxes, CastleRenderOptions, X3DNodes,
  BikeParametric, RiderTripo, RiderPoseCatalog, BikeGeometryLib, GameBikeAvatar, GameMenuTile;

type
  TBikeFitPage = class(TMenuEmbeddedPage)
  private
    FOnFootPreview,FOnFootFramed:Boolean;
    FPreviewAnimationPaused:Boolean;
    FWalkPreviewSpeed:Single;
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
    FHairBox:TCastleUserInterface;
    FAppearanceRows:TMenuScrollView;
    FWardrobePanel:TGameWardrobePanel;
    FHairSelect:TMenuButton;
    FHairPreview:TCastleImageControl;
    FHairTitle,FHairPopupTitle:TCastleLabel;
    FHairOverlay,FHairCard,FHairClose:TMenuButton;
    FHairScroll:TMenuScrollView;
    FHeadRows:array[0..3,0..8]of TMenuButton;
    FHeadPreviews,FHeadRearPreviews:array[0..3,0..8]of TCastleImageControl;
    FHeadChecks:array[0..3,0..8]of TCastleLabel;
    FHeadTabs:array[0..3]of TMenuButton;
    FHeadViews:array[0..2]of TMenuButton;
    FHeadSwatches:array[0..7]of TMenuButton;
    FHeadColorTitle,FHeadHint:TCastleLabel;
    FHeadCategory:Integer;
    FHeadLastCenter:TVector3;
    FHeadSavedCadence:Single;
    FHeadSavedAuto:Boolean;
    FHeadYaw:Single;
    FHeadCameraReady:Boolean;
    procedure ClickHeadCategory(Sender:TObject);
    procedure ClothingChanged(Sender:TObject);
    procedure ClickHeadView(Sender:TObject);
    procedure ClickHeadColor(Sender:TObject);
    procedure ScrollHeadSelection;
    procedure UpdateHeadCamera(Reset:Boolean);
    procedure ApplyHeadAppearance;
    procedure BuildHairSelector;
    procedure ApplyHairStyle;
    procedure ClickHair(Sender:TObject);
    procedure OpenHairList(Sender:TObject);
    procedure CloseHairList(Sender:TObject);
    procedure LayoutHairList;
  private
    FBikeControls,FCadenceControls,FEffortControls:TCastleUserInterface;
    FDyeTitle:TCastleLabel;
    FVpResult: TCastleViewport;
    FPreviewItems: TCastleRootTransform;
    FLiveRide, FLiveSettingsDirty: Boolean;
    FFitSaveDelay:Single;
    FValueButtons:array[0..12]of TCastleButton;
    FValueLabels:array[0..12]of TCastleLabel;
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
    FCadenceCaption, FEffortCaption: TCastleLabel;

    FNavResult: TCastleExamineNavigation;
    FLblPose, FLblCadence, FLblEffort, FLblResultInfo: TCastleLabel;
    FLblStack, FLblReach: TCastleLabel;
    FFitOverlay: TCastleRectangleControl;
    FBtnBikePick, FBtnSizePick, FBtnAutoFit: TCastleButton;
    FAutoFitPending: Boolean;
    FAutoFitStatus: Integer; { 0 normal, 1 fitted, 2 limited, 3 failed, 4 save failed }
    procedure ClickAutoFit(Sender: TObject);
    procedure RunAutoFit;
  private
    FBtnCadenceDown, FBtnCadenceUp: TCastleButton;
    FBtnEffortDown, FBtnEffortUp: TCastleButton;
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
    FPreviewEffortPct, FLastLiveEffortPct: Single;
    FFitSeatExt, FFitSaddleOff, FFitSpacers, FFitStem: Single;
    FFitHeightCm, FFitInseamCm, FFitWeightKg, FFitComposition: Single;
    FFitSex,FFitArmCm,FFitHead:Single;
    FBodyRows:TCastleScrollView;
    FBtnSexDown,FBtnSexUp,FBtnArmDown,FBtnArmUp,FBtnHeadDown,FBtnHeadUp:TCastleButton;
    FLblSex,FLblArm,FLblHead:TCastleLabel;
    procedure ClickBodyParameter(Sender:TObject);
    function CurrentBody:TRiderBodyParameters;
    procedure LoadBodyFields;
  private
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
    procedure ClickEffortDown(Sender: TObject);
    procedure ClickEffortUp(Sender: TObject);
    function CurrentEffortPct: Single;
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
    procedure ApplyPreviewAnimation;
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
    { MCP: endpoint presets on the shared body; dimensions are retained. }
    procedure McpSelectRider(AIndex: Integer);
    { MCP: AParam = height|inseam|bulk|belly|knee|ankle|seat|offset|spacers|stem|cadence|effort;
      ASteps signed, one UI click each. }
    procedure McpBody(AParams,AResult:TJSONObject);
    procedure McpAutoFit;
    procedure McpNudge(const AParam: string; ASteps: Integer);
    { MCP: цвет слота — jersey|shorts|socks|boots|gloves|skin|hair|frame|rim|
      helmet; AOn=False = «выкл» (сток). C — компоненты 0..1. }
    procedure McpSetColor(const ASlot: string; const C: TVector3; AOn: Boolean);
    procedure McpFillStatus(AResult: TJSONObject);
    procedure McpSetHair(const Id:String);
    procedure McpHead(AParams:TJSONObject;AResult:TJSONObject);
    procedure McpClothing(AParams:TJSONObject;AResult:TJSONObject);
    procedure McpCamera(AParams:TJSONObject;AResult:TJSONObject);
    procedure McpAnimation(AParams,AResult:TJSONObject);
    function KeyboardRoot:TCastleUserInterface;
    { MCP: свет превью/результата (env = IBL-ambient райдера, key/fill =
      вьюпорт, rkey/rfill = свети сцены райдера). Не указанный аргумент
      не меняется; эхом возвращает все значения + diag светов. }
    procedure McpLighting(AParams: TJSONObject; AResult: TJSONObject);
    function RiderCount: Integer;
  end;

var
  ViewBikeFit: TBikeFitPage;

implementation

uses GameTravelUI, CastleApplicationProperties,UiTranslations,GameUserData,
  jsonparser, CastleKeysMouse,CastleImages,CastleRectangles,
  GameViewMenu, GameViewPlay, AppSettings, DebugLog, GameBikeAutoFit;

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
  FOnFootPreview:=Settings.TravelMode<>travelBicycle;FOnFootFramed:=False;
  FWalkPreviewSpeed:=0;
  if FOnFootPreview and(FSection=0)then FSection:=1;
  FCadenceRpm := 80;
  FPreviewEffortPct := 70;
  FFitSeatExt := 150;
  FFitSaddleOff := 0;
  FFitSpacers := 20;
  FFitStem := 100;
  FFitHeightCm := 0;
  FFitInseamCm := 0;
  FFitWeightKg := 75;
  FFitComposition := 0.5;
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
  if ACaption = UiText('Load (% FTP)') then FEffortCaption := Cap;
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
  FHairOverlay:=nil;FHairCard:=nil;FHairSelect:=nil;
  FillChar(FHeadRows,SizeOf(FHeadRows),0);FillChar(FHeadChecks,SizeOf(FHeadChecks),0);
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
  BindUiText(FSectionButtons[0],'Bicycle');BindTravelText(FSectionButtons[1], 'Rider');
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

  FBtnAutoFit:=MakeNavBtn('Fit bike to rider',@ClickAutoFit,240,34);
  FBtnAutoFit.Name:='BikeFitAutoFit';
  FBtnAutoFit.Enabled:=False;
  TMenuButton(FBtnAutoFit).Style:=mbPrimary;
  FColParams.InsertFront(FBtnAutoFit);

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

  FBodyRows:=TCastleScrollView.Create(FUiOwner);
  FBodyRows.FullSize:=True; FColParams.InsertFront(FBodyRows);
  FBodyRows.ScrollArea.AutoSizeToChildren:=False;
  FBodyRows.ScrollArea.WidthFraction:=1;
  MakeFitRow(FBodyRows.ScrollArea, UiText('Height'), -286,
    FBtnHeightDown, FBtnHeightUp, FLblHeight);
  FBtnHeightDown.OnClick := @ClickHeightDown;
  FBtnHeightUp.OnClick := @ClickHeightUp;

  MakeFitRow(FBodyRows.ScrollArea, UiText('Inseam'), -324,
    FBtnInseamDown, FBtnInseamUp, FLblInseam);
  FBtnInseamDown.OnClick := @ClickInseamDown;
  FBtnInseamUp.OnClick := @ClickInseamUp;

  MakeFitRow(FBodyRows.ScrollArea, UiText('Weight (kg)'), -362,
    FBtnBulkDown, FBtnBulkUp, FLblBulk);
  FBtnBulkDown.OnClick := @ClickBulkDown;
  FBtnBulkUp.OnClick := @ClickBulkUp;

  MakeFitRow(FBodyRows.ScrollArea, UiText('Soft / muscular'), -400,
    FBtnBellyDown, FBtnBellyUp, FLblBelly);
  FBtnBellyDown.OnClick := @ClickBellyDown;
  FBtnBellyUp.OnClick := @ClickBellyUp;

  MakeFitRow(FBodyRows.ScrollArea, UiText('Knees'), -438,
    FBtnKneeDown, FBtnKneeUp, FLblKnee);
  FBtnKneeDown.OnClick := @ClickKneeDown;
  FBtnKneeUp.OnClick := @ClickKneeUp;

  MakeFitRow(FBodyRows.ScrollArea, UiText('Feet'), -476,
    FBtnAnkleDown, FBtnAnkleUp, FLblAnkle);
  FBtnAnkleDown.OnClick := @ClickAnkleDown;
  FBtnAnkleUp.OnClick := @ClickAnkleUp;

  MakeFitRow(FBodyRows.ScrollArea,UiText('Body: MEN / FEM'),0,FBtnSexDown,FBtnSexUp,FLblSex);
  FBtnSexDown.Tag:=-1;FBtnSexUp.Tag:=1;
  FBtnSexDown.OnClick:=@ClickBodyParameter;FBtnSexUp.OnClick:=@ClickBodyParameter;
  MakeFitRow(FBodyRows.ScrollArea,UiText('Arm length'),0,FBtnArmDown,FBtnArmUp,FLblArm);
  FBtnArmDown.Tag:=-2;FBtnArmUp.Tag:=2;
  FBtnArmDown.OnClick:=@ClickBodyParameter;FBtnArmUp.OnClick:=@ClickBodyParameter;
  MakeFitRow(FBodyRows.ScrollArea,UiText('Head: MEN / FEM'),0,FBtnHeadDown,FBtnHeadUp,FLblHead);
  FBtnHeadDown.Tag:=-3;FBtnHeadUp.Tag:=3;
  FBtnHeadDown.OnClick:=@ClickBodyParameter;FBtnHeadUp.OnClick:=@ClickBodyParameter;

  FCadenceControls:=MakeParamBlock(FColParams, UiText('Cadence (preview)'), -520,
    FBtnCadenceDown, FBtnCadenceUp, FLblCadence);
  FBtnCadenceDown.Caption := '−';
  FBtnCadenceUp.Caption := '+';
  FBtnCadenceDown.OnClick := @ClickCadenceDown;
  FBtnCadenceUp.OnClick := @ClickCadenceUp;

  FEffortControls := MakeParamBlock(FColParams, UiText('Load (% FTP)'), -520,
    FBtnEffortDown, FBtnEffortUp, FLblEffort);
  FBtnEffortDown.Name := 'BikeFitEffortDown';
  FBtnEffortUp.Name := 'BikeFitEffortUp';
  FBtnEffortDown.Caption := '−';
  FBtnEffortUp.Caption := '+';
  FBtnEffortDown.OnClick := @ClickEffortDown;
  FBtnEffortUp.OnClick := @ClickEffortUp;

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
  FAppearanceRows:=TMenuScrollView.Create(FUiOwner);
  FAppearanceRows.ScrollArea.AutoSizeToChildren:=False;
  FAppearanceRows.ScrollArea.WidthFraction:=1;
  FAppearanceRows.FullSize:=True;FColParams.InsertFront(FAppearanceRows);
  BuildColorStrip;
  BuildHairSelector;
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
  if FOnFootPreview then begin
    Radius:=CurrentBody.HeightCm/100;
    BoxCenter:=Vector3(0,Radius*0.5,0);
    Dir:=Vector3(-0.35,-0.08,-1).Normalize;
    Dist:=Radius*1.5;
    AVp.Camera.SetView(BoxCenter-Dir*Dist,Dir,DefaultCamUp);
    FNavResult.ModelBox:=Box3D(Vector3(-0.5,0,-0.4),Vector3(0.5,Radius,0.4));
    Exit;
  end;
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
  FLastLiveEffortPct := CurrentEffortPct;
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
  if (FHairOverlay<>nil)and FHairOverlay.Exists then UpdateHeadCamera(False)
  else UpdateLiveCamera(False);
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
  FOnFootPreview:=Settings.TravelMode<>travelBicycle;FOnFootFramed:=False;
  FWalkPreviewSpeed:=0;
  if FOnFootPreview and(FSection=0)then FSection:=1;
  if FLabelTitle <> nil then
    FLabelTitle.Exists := False;
  if FButtonBack <> nil then
    FButtonBack.Exists := False;
  BindUiText(FButtonApply, 'Save bike fit');FButtonApply.Exists:=False;FPoseAuto:=False;
  FAutoFitStatus:=0;
  FCadenceRpm := 80;
  BindUiText(FBtnAutoFit,'Fit bike to rider');
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

  LoadBodyFields;
  if FUiOwner = nil then
    BuildLayout;
  LayoutSections;
  ApplyHairStyle;
  FWardrobePanel.Refresh;
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

  if (Settings.TravelMode<>travelFlight) and Assigned(ViewPlay) and ViewPlay.SessionAlive and ViewMenu.RideUnderneath then
    AttachLiveRide
  else
    FDirtyResult := True;
  FBtnCadenceDown.Enabled := not FLiveRide;
  FBtnCadenceUp.Enabled := not FLiveRide;
  FBtnEffortDown.Enabled := not FLiveRide;
  FBtnEffortUp.Enabled := not FLiveRide;
  if FCadenceCaption <> nil then
    if FOnFootPreview then BindUiText(FCadenceCaption,'Walking speed')
    else if FLiveRide then BindUiText(FCadenceCaption, 'Ride cadence')
    else BindUiText(FCadenceCaption, 'Cadence (preview)');
  UpdateLabels;
end;

procedure TBikeFitPage.PageHidden;
begin
  FPreviewAnimationPaused:=False;
  { Bike BuildYield can dispatch a queued tab switch. Release the scene only
    after the active rebuild returns, never from inside that rebuild. }
  if FLoadingPreview then
  begin
    FReleasePreviewPending := True;
    Exit;
  end;
  if FLiveSettingsDirty then ClickApply(nil);
  FAutoFitPending:=False;
  CancelValue(nil);ClosePopup;CloseHairList(nil);
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
  Result:=WardrobeRiderPath(Result);
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
  I, Pass, Shown, Hidden: Integer;
  Featured: Boolean;
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
  for Pass := 0 to 1 do
  for I := 0 to FBikeNames.Count - 1 do
  begin
    BikeName := FBikeNames[I];
    Featured := SameText(ExtractFileName(FBikePaths[I]),'rezvivo-trail-mtb.json') or
      SameText(ExtractFileName(FBikePaths[I]),'rezvivo-track-fixed.json');
    if Featured <> (Pass = 0) then Continue;
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
    FPopupList.InsertFront(Btn);
    Inc(Shown);
  end;
  if Hidden > 0 then
  begin
    Hint := TMenuLabel.Create(FUiOwner);
    Hint.Caption := Format(UiText('%d more — refine your search'), [Hidden]);
    Hint.Color := MenuMuted;
    Hint.FontScale := 0.8;
    FPopupList.InsertFront(Hint);
  end
  else if Shown = 0 then
  begin
    Hint := TMenuLabel.Create(FUiOwner);
    BindUiText(Hint, 'no results');
    Hint.Color := MenuMuted;
    Hint.FontScale := 0.85;
    FPopupList.InsertFront(Hint);
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
    FPopupList.InsertFront(Btn);
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
  FAutoFitStatus:=0;
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
  FAutoFitStatus:=0;
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

procedure TBikeFitPage.ApplyPreviewAnimation;
var
  CrankIntv: Single;
  SpeedMps: Single;
begin
  if FLiveRide or (FResultBike = nil) then Exit;
  FResultBike.SetRiderEffort(FPreviewEffortPct / 100);
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
  { The fixed sprocket must keep the wheels and cranks in the same ratio. }
  SpeedMps := (FCadenceRpm / 60.0) * FResultBike.DriveMetresPerCrankRevolution;
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
    Logger.Info(Format('[BikeFit] LoadTripoRider %s ok=%s restH=%0.3f m %d ms',
      [ExtractFileName(Rider), BoolToStr(Ok, True),
       FResultBike.TripoRider.RestHeight, GetTickCount64 - T0]))
  else
    Logger.Info(Format('[BikeFit] LoadTripoRider %s ok=%s %d ms',
      [ExtractFileName(Rider), BoolToStr(Ok, True), GetTickCount64 - T0]));
  ApplyRiderShapeToPreview;
  FitCameraToItems(FVpResult);
  ApplyPreviewAnimation;
  FPoseTimer := 0;
  ApplyResultPose;
  ReapplyHelmetColor;
  ApplyHairStyle;
  ApplyRiderShaderDye;
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
    Logger.Info(Format('[BikeFit] LoadPrepared %s ok=%s restH=%0.3f m %d ms',
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
  if FLiveRide then UpdateLiveCamera(True)else FitCameraToItems(FVpResult);
  Logger.Info(Format('[BikeFit]   FitCamera %d ms', [GetTickCount64 - T0]));
  T0 := GetTickCount64;
  ApplyPreviewAnimation;
  FPoseTimer := 0;
  ApplyResultPose;
  ReapplyColorsAfterBuild;
  Logger.Info(Format('[BikeFit]   Pose %d ms', [GetTickCount64 - T0]));
  if FLiveRide then ViewPlay.BikeFitChanged;
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
    ApplyPreviewAnimation;
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
  ApplyHairStyle;
  LayoutSections;
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
    if FOnFootPreview then FLblCadence.Caption:=Format('%.1f km/h',[FWalkPreviewSpeed*3.6])
    else FLblCadence.Caption := Format(UiText('%d rpm'), [Round(FCadenceRpm)]);
  if FLblEffort <> nil then
    FLblEffort.Caption := IntToStr(Round(CurrentEffortPct)) + '%';
  if FLblSeatH <> nil then
    FLblSeatH.Caption := Format(UiText('%0.0f mm'), [FFitSeatExt]);
  if FLblSeatO <> nil then
  begin
    if FFitSaddleOff > 0.5 then
      FLblSeatO.Caption := '+' + IntToStr(Round(FFitSaddleOff)) + UiText(' mm')
    else
      FLblSeatO.Caption := IntToStr(Round(FFitSaddleOff)) + UiText(' mm');
  end;
  if FLblSpacers <> nil then
    FLblSpacers.Caption := Format(UiText('%0.0f mm'), [FFitSpacers]);
  if FLblStem <> nil then
    FLblStem.Caption := Format(UiText('%0.0f mm'), [FFitStem]);
  if FLblHeight <> nil then
    FLblHeight.Caption := Format(UiText('%0.0f cm'), [FFitHeightCm]);
  if FLblInseam <> nil then
    FLblInseam.Caption := Format(UiText('%0.0f cm'), [RiderBodyInseamCm(CurrentBody)]);
  if FLblBulk<>nil then FLblBulk.Caption:=Format('%0.1f',[FFitWeightKg]);
  if FLblBelly<>nil then FLblBelly.Caption:=IntToStr(Round(FFitComposition*100))+'%';
  if FLblSex<>nil then FLblSex.Caption:=IntToStr(Round(FFitSex*100))+'%';
  if FLblHead<>nil then FLblHead.Caption:=IntToStr(Round(FFitHead*100))+'%';
  if FLblArm<>nil then FLblArm.Caption:=Format(UiText('%0.1f cm'),[RiderBodyArmCm(CurrentBody)]);
  if FLblKnee <> nil then
  begin
    if Abs(FFitKneeFlare) < 0.005 then
      FLblKnee.Caption := '0'
    else if FFitKneeFlare > 0 then
      FLblKnee.Caption := '+' + Format('%0.2f', [FFitKneeFlare])
    else
      FLblKnee.Caption := Format('%0.2f', [FFitKneeFlare]);
  end;
  if FLblAnkle <> nil then
    FLblAnkle.Caption := IntToStr(Round(FFitAnkleFlex)) + '°';
  for I:=0 to High(FValueButtons)do if(FValueButtons[I]<>nil)and(FValueLabels[I]<>nil)then
    FValueButtons[I].Caption:=FValueLabels[I].Caption;
  UpdateReachStackOverlay;
  if FLblResultInfo <> nil then
    FLblResultInfo.Caption := Format(UiText('%d rpm'), [Round(FCadenceRpm)]);
  if FLiveRide and (FLblPose <> nil) then
    BindTravelText(FLblPose, 'Ride pose and animation');
  if FLabelStatus <> nil then
    BindUiText(FLabelStatus, 'Changes saved automatically');
  if FLiveRide and (FLabelStatus <> nil) then
    BindTravelText(FLabelStatus, 'Changes apply to the rider in the current ride');
  if FLabelStatus<>nil then case FAutoFitStatus of
    1:BindUiText(FLabelStatus,'Bike fit applied and saved. You can fine-tune it below.');
    2:BindUiText(FLabelStatus,'Closest bike fit saved. This model has limited adjustment for these body proportions.');
    3:BindUiText(FLabelStatus,'Could not fit this bicycle. Choose a model with frame size data.');
    4:BindUiText(FLabelStatus,'Could not save settings. Please try again.');
  end;
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

function DyeSlotTitle(Index:Integer):string;
begin
  Result:=DyeSlotCaption[Index];
  case Index of
    0:if WardrobeSelection(2)<>''then Result:='Outer layer'
      else if WardrobeSelection(0)<>''then Result:='Top';
    1:if WardrobeSelection(1)<>''then Result:='Bottom';
    3:Result:='Footwear';
    9:if(WardrobeSelection(4)<>'')or(UserPreference('rider_headwear','helmet')<>'helmet')then Result:='Headwear';
  end;
end;

const
  HeadCategories:array[0..3]of String=('Headwear','Hairstyle','Mustache','Beard');
  HeadKeys:array[0..3]of String=('rider_headwear','rider_hair_style','rider_mustache','rider_beard');
  HeadDefaults:array[0..3]of String=('helmet','short','none','none');
  HeadViewNames:array[0..2]of String=('Front view','Side view','Rear view');
function HeadOptionCount(Category:Integer):Integer;
begin case Category of 0:Result:=4;1:Result:=Length(SelectableHairStyles);2:Result:=4;else Result:=5 end end;
function HeadOptionId(Category,Index:Integer):String;
begin
  case Category of 0:Result:=HeadwearId(TRiderHeadwear(Index));
    1:Result:=RiderHairStyleId(SelectableHairStyles[Index]);
    2:Result:=MustacheId(TRiderMustache(Index));else Result:=BeardId(TRiderBeard(Index)) end;
end;
function HeadOptionCaption(Category,Index:Integer):String;
begin
  case Category of 0:Result:=HeadwearCaption(TRiderHeadwear(Index));
    1:Result:=RiderHairStyleCaption(SelectableHairStyles[Index]);
    2:Result:=MustacheCaption(TRiderMustache(Index));else Result:=BeardCaption(TRiderBeard(Index)) end;
end;
function HeadPreviewUrl(Category:Integer;const Id:String;Rear:Boolean):String;
const Prefix:array[0..3]of String=('headwear','hair','mustache','beard');
var Name:String;
begin
  Name:=Prefix[Category]+'_'+Id;if Rear then Name:=Name+'-rear';
  Result:=ApplicationData('menu/head/'+Name+'.png');
  if not FileExists(URIToFilenameSafe(Result))then Result:='';
end;

procedure TBikeFitPage.BuildHairSelector;
var C,I:Integer;B:TMenuButton;L:TCastleLabel;
begin
  FWardrobePanel:=TGameWardrobePanel.Create(FUiOwner);
  FWardrobePanel.OnChange:=@ClothingChanged;
  FWardrobePanel.OnColorClick:=@ClickDyeSlot;
  FAppearanceRows.ScrollArea.InsertFront(FWardrobePanel);
  FHairBox:=TCastleUserInterface.Create(FUiOwner);
  FAppearanceRows.ScrollArea.InsertFront(FHairBox);
  FHairBox.Anchor(hpMiddle);FHairBox.Anchor(vpTop);
  FHairTitle:=TMenuLabel.Create(FUiOwner);BindUiText(FHairTitle,'Head');
  FHairTitle.Color:=MenuText;FHairTitle.Anchor(hpLeft,6);FHairTitle.Anchor(vpTop,-4);
  FHairBox.InsertFront(FHairTitle);
  FHairSelect:=TMenuButton.Create(FUiOwner);FHairSelect.Name:='HairStylePicker';
  FHairSelect.AutoIcon:=False;FHairSelect.AutoSize:=False;
  FHairSelect.Alignment:=hpLeft;FHairSelect.TextAlignment:=hpLeft;
  FHairSelect.OnClick:=@OpenHairList;
  FHairSelect.Anchor(hpMiddle);FHairSelect.Anchor(vpBottom);
  FHairBox.InsertFront(FHairSelect);
  FHairPreview:=TCastleImageControl.Create(FUiOwner);
  FHairPreview.Stretch:=True;
  FHairPreview.Anchor(hpLeft,8);FHairPreview.Anchor(vpMiddle);
  FHairPreview.CapturesEvents:=False;FHairSelect.InsertFront(FHairPreview);
  L:=TMenuLabel.Create(FUiOwner);L.Caption:='›';L.Color:=MenuMuted;
  L.Anchor(hpRight,-10);L.Anchor(vpMiddle);L.CapturesEvents:=False;
  FHairSelect.InsertFront(L);

  { A normal list of baked portraits: no extra animated riders or render passes.
    The transparent outside button closes the list without activating controls
    underneath. The large rider preview remains visible on the right. }
  FHairOverlay:=TMenuButton.Create(FUiOwner);FHairOverlay.AutoIcon:=False;
  FHairOverlay.AutoSize:=False;FHairOverlay.HeightFraction:=1;FHairOverlay.Anchor(hpLeft);
  FHairOverlay.CustomColorNormal:=Vector4(0,0,0,0.22);
  FHairOverlay.CustomColorFocused:=FHairOverlay.CustomColorNormal;
  FHairOverlay.CustomColorPressed:=FHairOverlay.CustomColorNormal;
  FHairOverlay.OnClick:=@CloseHairList;FHairOverlay.Exists:=False;
  FBottomRow.InsertFront(FHairOverlay);
  FHairCard:=TMenuButton.Create(FUiOwner);FHairCard.AutoIcon:=False;
  FHairCard.AutoSize:=False;FHairCard.CustomColorNormal:=MenuSurface;
  FHairCard.CustomColorFocused:=MenuSurface;FHairCard.CustomColorPressed:=MenuSurface;
  FHairCard.OnClick:=@ClickPopupCard;FHairCard.Anchor(hpLeft);
  FHairOverlay.InsertFront(FHairCard);
  FHairPopupTitle:=TMenuLabel.Create(FUiOwner);BindUiText(FHairPopupTitle,'Head editor');
  FHairPopupTitle.Anchor(hpLeft,12);FHairPopupTitle.Anchor(vpTop,-12);
  FHairPopupTitle.CapturesEvents:=False;FHairCard.InsertFront(FHairPopupTitle);
  FHairClose:=TMenuButton.Create(FUiOwner);FHairClose.AutoIcon:=False;FHairClose.AutoSize:=False;
  FHairClose.Name:='HairStyleClose';FHairClose.Caption:='×';FHairClose.OnClick:=@CloseHairList;
  FHairClose.Anchor(hpRight,-8);FHairClose.Anchor(vpTop,-8);FHairCard.InsertFront(FHairClose);
  FHairScroll:=TMenuScrollView.Create(FUiOwner);FHairScroll.Name:='HairStyleList';
  FHairScroll.ScrollArea.AutoSizeToChildren:=False;FHairScroll.ScrollArea.WidthFraction:=1;
  FHairScroll.FullSize:=True;FHairCard.InsertFront(FHairScroll);
  for C:=0 to 3 do begin
    B:=TMenuButton.Create(FUiOwner);FHeadTabs[C]:=B;
    B.Name:='HeadCategory'+IntToStr(C);B.Tag:=C;B.AutoIcon:=False;B.AutoSize:=False;
    BindUiText(B,HeadCategories[C]);B.OnClick:=@ClickHeadCategory;FHairCard.InsertFront(B);
    for I:=0 to HeadOptionCount(C)-1 do begin
    B:=TMenuButton.Create(FUiOwner);FHeadRows[C,I]:=B;
    B.Name:='HeadOption'+IntToStr(C)+'_'+HeadOptionId(C,I);B.Tag:=C*16+I;
    B.AutoIcon:=False;B.AutoSize:=False;B.Alignment:=hpLeft;B.TextAlignment:=hpLeft;
    B.OnClick:=@ClickHair;B.Anchor(hpLeft);FHairScroll.ScrollArea.InsertFront(B);
    FHeadPreviews[C,I]:=TCastleImageControl.Create(FUiOwner);
    with FHeadPreviews[C,I]do begin
      Stretch:=True;
      Url:=HeadPreviewUrl(C,HeadOptionId(C,I),False);
      Anchor(hpLeft,8);Anchor(vpMiddle);CapturesEvents:=False;
    end;
    B.InsertFront(FHeadPreviews[C,I]);
    FHeadRearPreviews[C,I]:=TCastleImageControl.Create(FUiOwner);
    with FHeadRearPreviews[C,I]do begin
      Stretch:=True;Url:=HeadPreviewUrl(C,HeadOptionId(C,I),True);
      Anchor(vpMiddle);CapturesEvents:=False;
    end;
    B.InsertFront(FHeadRearPreviews[C,I]);
    L:=TMenuLabel.Create(FUiOwner);FHeadChecks[C,I]:=L;L.Caption:='✓';
    L.Color:=MenuAccent;L.Anchor(hpRight,-10);L.Anchor(vpMiddle);
    L.CapturesEvents:=False;B.InsertFront(L);
    end;
  end;
  FHeadColorTitle:=TMenuLabel.Create(FUiOwner);FHeadColorTitle.Color:=MenuMuted;FHairCard.InsertFront(FHeadColorTitle);
  for I:=0 to High(FHeadSwatches)do begin
    B:=TMenuButton.Create(FUiOwner);FHeadSwatches[I]:=B;B.AutoIcon:=False;B.AutoSize:=False;
    B.Tag:=I;B.Name:='HeadColor'+IntToStr(I);B.Caption:='';B.OnClick:=@ClickHeadColor;FHairCard.InsertFront(B);
  end;
  for I:=0 to High(FHeadViews)do begin
    B:=TMenuButton.Create(FUiOwner);FHeadViews[I]:=B;B.AutoIcon:=False;B.AutoSize:=False;
    B.Tag:=I;B.Name:='HeadView'+IntToStr(I);BindUiText(B,HeadViewNames[I]);
    B.OnClick:=@ClickHeadView;B.Exists:=False;FColResult.InsertFront(B);
  end;
  FHeadHint:=TMenuLabel.Create(FUiOwner);BindUiText(FHeadHint,'Drag to rotate · Wheel to zoom');
  FHeadHint.Color:=MenuMuted;FHeadHint.Exists:=False;FColResult.InsertFront(FHeadHint);
  ApplyHairStyle;
end;

procedure TBikeFitPage.ApplyHairStyle;
var Style:TRiderHairStyle;C,I:Integer;Selected:Boolean;Id:String;
begin
  Style:=ParseRiderHairStyle(UserPreference('rider_hair_style','short'));
  if FHairSelect<>nil then begin
    BindUiText(FHairSelect,'Head editor');
    FHairPreview.Url:=HeadPreviewUrl(1,RiderHairStyleId(Style),False);
  end;
  for C:=0 to 3 do begin
    Id:=UserPreference(HeadKeys[C],HeadDefaults[C]);
    if C=1 then Id:=RiderHairStyleId(Style);
    for I:=0 to HeadOptionCount(C)-1 do if FHeadRows[C,I]<>nil then begin
      Selected:=HeadOptionId(C,I)=Id;SelectMenuButton(FHeadRows[C,I],Selected);
      FHeadChecks[C,I].Exists:=Selected;
    end;
  end;
  if(FResultBike<>nil)and(FResultBike.TripoRider<>nil)then FResultBike.TripoRider.HairStyle:=Style;
  ApplyHeadAppearance;
  UpdateDyeStripVisuals;
end;

procedure TBikeFitPage.ClothingChanged(Sender:TObject);
begin
  CloseHairList(nil);FOnFootFramed:=False;
  UpdateDyeStripVisuals;
  if FResultBike<>nil then RequestResultRider(CurrentRiderPath)
  else FDirtyResult:=True;
  LiveFitChanged;
end;

procedure TBikeFitPage.McpClothing(AParams:TJSONObject;AResult:TJSONObject);
var I:Integer;Changed:Boolean;
begin
  Changed:=False;
  for I:=0 to High(WardrobeSlots)do if AParams.Find(WardrobeSlots[I])<>nil then begin
    SelectWardrobe(WardrobeSlots[I],AParams.Get(WardrobeSlots[I],''));Changed:=True;
  end;
  if Changed then begin FWardrobePanel.Refresh;ClothingChanged(nil) end;
  FSection:=2;LayoutSections;McpFillStatus(AResult);AResult.Add('ok',True);
end;

procedure TBikeFitPage.McpCamera(AParams:TJSONObject;AResult:TJSONObject);
var P,D,U,C,V:TVector3;Zoom,Yaw,SinY,CosY,TargetY:Single;
begin
  if FLiveRide then raise EArgumentException.Create('Use camera.set_view for an active ride');
  if(FVpResult=nil)or(FResultBike=nil)then raise EArgumentException.Create('Avatar preview is not ready');
  Zoom:=AParams.Get('zoom',1.0);Yaw:=AParams.Get('yaw',0.0);
  if IsNan(Zoom)or IsInfinite(Zoom)or(Zoom<0.5)or(Zoom>4)or
    IsNan(Yaw)or IsInfinite(Yaw)or(Abs(Yaw)>360)then
    raise EArgumentException.Create('Invalid preview camera zoom/yaw');
  FitCameraToItems(FVpResult);FOnFootFramed:=True;
  FVpResult.Camera.GetWorldView(P,D,U);
  if FOnFootPreview then C:=Vector3(0,CurrentBody.HeightCm/200,0)
  else C:=FVpResult.Items.BoundingBox.Center;
  V:=(P-C)/Zoom;SinY:=Sin(DegToRad(Yaw));CosY:=Cos(DegToRad(Yaw));
  if AParams.Find('target_y')<>nil then begin
    TargetY:=AParams.Get('target_y',Double(C.Y));
    if IsNan(TargetY)or IsInfinite(TargetY)or(TargetY<0)or(TargetY>2.5)then
      raise EArgumentException.Create('Invalid preview camera target_y');
    C.Y:=TargetY;
  end;
  P:=C+Vector3(V.X*CosY-V.Z*SinY,V.Y,V.X*SinY+V.Z*CosY);
  FVpResult.Camera.SetWorldView(P,(C-P).Normalize,U);
  McpFillStatus(AResult);
end;

procedure TBikeFitPage.ApplyHeadAppearance;
begin
  if (FResultBike=nil)or(FResultBike.TripoRider=nil)then Exit;
  FResultBike.TripoRider.SetHeadAppearance(WardrobeHeadwear,
    ParseBeard(UserPreference(HeadKeys[3],HeadDefaults[3])),ParseMustache(UserPreference(HeadKeys[2],HeadDefaults[2])));
end;

procedure TBikeFitPage.McpSetHair(const Id:String);
var Style:TRiderHairStyle;
begin
  Style:=ParseRiderHairStyle(Id);
  if not SameText(Id,RiderHairStyleId(Style))then raise Exception.Create('Unknown hairstyle: '+Id);
  SetUserPreference('rider_hair_style',RiderHairStyleId(Style));
  FSection:=2;ApplyHairStyle;LayoutSections;
end;

procedure TBikeFitPage.ClickHair(Sender:TObject);
var C,I:Integer;
begin
  C:=TMenuButton(Sender).Tag div 16;I:=TMenuButton(Sender).Tag mod 16;
  if(C=0)and(WardrobeSelection(4)<>'')then begin
    SelectWardrobe('head','');FWardrobePanel.Refresh;ClothingChanged(nil);
  end;
  SetUserPreference(HeadKeys[C],HeadOptionId(C,I));ApplyHairStyle;LayoutHairList;
  if C=1 then UpdateHeadCamera(True);
end;

procedure TBikeFitPage.McpHead(AParams:TJSONObject;AResult:TJSONObject);
const Params:array[0..3]of String=('headwear','hair','mustache','beard');
var C,I:Integer;Id,Path:String;Found:Boolean;Img:TRGBImage;R:TFloatRectangle;Side:Single;
begin
  for C:=0 to 3 do if AParams.Find(Params[C])<>nil then begin
    Id:=AParams.Get(Params[C],'');Found:=False;
    for I:=0 to HeadOptionCount(C)-1 do if Id=HeadOptionId(C,I)then Found:=True;
    if not Found then raise Exception.Create('Unknown '+Params[C]+': '+Id);
    if(C=0)and(WardrobeSelection(4)<>'')then begin
      SelectWardrobe('head','');FWardrobePanel.Refresh;ClothingChanged(nil);
    end;
    SetUserPreference(HeadKeys[C],Id);
  end;
  FSection:=2;ApplyHairStyle;LayoutSections;
  if AParams.Get('open',True)then begin
    if not FHairOverlay.Exists then OpenHairList(nil);
    FHeadCategory:=EnsureRange(AParams.Get('category',FHeadCategory),0,3);
    FHeadYaw:=AParams.Get('yaw',Double(FHeadYaw));LayoutHairList;ScrollHeadSelection;UpdateHeadCamera(True);
  end else CloseHairList(nil);
  if ((AParams.Find('jaw')<>nil)or(AParams.Find('smile')<>nil)or
      (AParams.Find('strain')<>nil)or(AParams.Find('manual_face')<>nil))and
     (FResultBike<>nil)and(FResultBike.TripoRider<>nil)and
     (FResultBike.TripoRider.Face<>nil)then
    FResultBike.TripoRider.Face.SetExpression(AParams.Get('manual_face',True),
      AParams.Get('jaw',0.0),AParams.Get('smile',0.0),AParams.Get('strain',0.0));
  Path:=AParams.Get('thumbnail','');
  if Path<>'' then begin
    if (FResultBike=nil)or(FResultBike.TripoRider=nil)or not FResultBike.TripoRider.Loaded then
      raise Exception.Create('Head preview is not ready');
    R:=FVpResult.RenderRect;Side:=Min(R.Width,R.Height-110);
    R:=FloatRectangle(R.Left+(R.Width-Side)*0.5,R.Bottom+(R.Height-Side)*0.5,Side,Side);
    FFitOverlay.Exists:=False;
    try
      Img:=Container.SaveScreen(R);
      try Img.Resize(192,192);SaveImage(Img,FilenameToUriSafe(Path)) finally Img.Free end;
    finally FFitOverlay.Exists:=not FHairOverlay.Exists end;
  end;
  McpFillStatus(AResult);
end;

procedure TBikeFitPage.OpenHairList(Sender:TObject);
begin
  ClosePopup;CloseDyePopup;ApplyHairStyle;
  if not FHairOverlay.Exists then begin
    FHeadSavedCadence:=FCadenceRpm;FHeadSavedAuto:=FPoseAuto;
    if not FLiveRide then begin FCadenceRpm:=0;FPoseAuto:=False;ApplyPreviewAnimation;UpdateLabels end;
  end;
  FHairOverlay.Exists:=True;UpdateLabels;LayoutHairList;
  FHeadYaw:=30;UpdateHeadCamera(True);ScrollHeadSelection;
end;

procedure TBikeFitPage.CloseHairList(Sender:TObject);
var I:Integer;
begin
  if (FHairOverlay=nil)or not FHairOverlay.Exists then Exit;
  FHairOverlay.Exists:=False;
  FHeadCameraReady:=False;
  UpdateLabels;
  LayoutSections;FFitOverlay.Exists:=True;
  for I:=0 to High(FHeadViews)do FHeadViews[I].Exists:=False;
  FHeadHint.Exists:=False;
  if not FLiveRide then begin FCadenceRpm:=FHeadSavedCadence;FPoseAuto:=FHeadSavedAuto;ApplyPreviewAnimation;UpdateLabels end;
  FitCameraToItems(FVpResult);
end;

function TBikeFitPage.KeyboardRoot:TCastleUserInterface;
begin
  Result:=nil;
  if(FHairOverlay<>nil)and FHairOverlay.Exists then Result:=FHairCard;
end;

procedure TBikeFitPage.LayoutHairList;
const HairColors:array[0..7]of TVector3=((X:0.09;Y:0.065;Z:0.050),(X:0.26;Y:0.17;Z:0.105),
  (X:0.43;Y:0.26;Z:0.12),(X:0.68;Y:0.36;Z:0.16),(X:0.79;Y:0.66;Z:0.42),
  (X:0.90;Y:0.83;Z:0.65),(X:0.52;Y:0.52;Z:0.50),(X:0.91;Y:0.91;Z:0.88));
  HatColors:array[0..7]of TVector3=((X:0.12;Y:0.14;Z:0.17),(X:0.94;Y:0.93;Z:0.88),
  (X:0.20;Y:0.38;Z:0.53),(X:0.17;Y:0.40;Z:0.32),(X:0.72;Y:0.18;Z:0.17),
  (X:0.86;Y:0.59;Z:0.23),(X:0.47;Y:0.30;Z:0.53),(X:0.75;Y:0.41;Z:0.50));
var S,W,ImageW:Single;I,C:Integer;B:TMenuButton;Color:TVector3;
begin
  if FHairCard=nil then Exit;
  if FHairOverlay.Exists then begin
    FPosePrev.Exists:=False;FPoseNext.Exists:=False;FPoseToggle.Exists:=False;
    FLblPose.Exists:=False;FFitOverlay.Exists:=False;
  end;
  S:=Max(0.65,Min(1,UIScale));
  W:=FColParams.Width;FHairOverlay.Width:=W;
  FHairCard.Width:=W-8/S;FHairCard.Height:=FBottomRow.EffectiveHeight-8/S;
  FHairCard.Anchor(vpTop,-4/S);
  FHairPopupTitle.FontSize:=16/S;
  FHairClose.Width:=32/S;FHairClose.Height:=32/S;FHairClose.FontSize:=20/S;
  FHairScroll.Border.Top:=134/S;FHairScroll.Border.Bottom:=90/S;
  FHairScroll.Border.Left:=8/S;FHairScroll.Border.Right:=8/S;
  FHairScroll.ScrollArea.Height:=HeadOptionCount(FHeadCategory)*94/S;
  ImageW:=Min(85/S,(W-130/S)*0.5);
  for C:=0 to 3 do begin
    B:=FHeadTabs[C];B.Width:=(W-32/S)*0.5;B.Height:=34/S;B.FontSize:=14/S;
    B.Anchor(hpLeft,8/S+(C mod 2)*(B.Width+6/S));B.Anchor(vpTop,-(48+(C div 2)*40)/S);
    SelectMenuButton(B,C=FHeadCategory);
    for I:=0 to HeadOptionCount(C)-1 do begin
    B:=FHeadRows[C,I];B.Exists:=C=FHeadCategory;B.Width:=FHairCard.Width-26/S;B.Height:=88/S;
    B.Anchor(vpTop,-I*94/S);B.FontScale:=1;B.FontSize:=14/S;
    B.PaddingHorizontal:=2*ImageW+16/S;B.PaddingVertical:=6/S;
    FHeadPreviews[C,I].Width:=ImageW;FHeadPreviews[C,I].Height:=ImageW;
    FHeadPreviews[C,I].Anchor(hpLeft,4/S);
    FHeadRearPreviews[C,I].Width:=ImageW;FHeadRearPreviews[C,I].Height:=ImageW;
    FHeadRearPreviews[C,I].Anchor(hpLeft,8/S+ImageW);
    B.Caption:=MenuSummary(UiText(HeadOptionCaption(C,I)),B.Font,(B.Width-2*ImageW-44/S)*UIScale,3);
    FHeadChecks[C,I].FontSize:=16/S;
    end;
  end;
  if FHeadCategory=0 then BindUiText(FHeadColorTitle,'Headwear color')else BindUiText(FHeadColorTitle,'Hair and facial hair color');
  FHeadColorTitle.FontSize:=13/S;FHeadColorTitle.Anchor(hpLeft,12/S);FHeadColorTitle.Anchor(vpBottom,58/S);
  for I:=0 to High(FHeadSwatches)do begin
    B:=FHeadSwatches[I];B.Width:=(W-38/S)/8;B.Height:=32/S;
    B.Anchor(hpLeft,10/S+I*(B.Width+2/S));B.Anchor(vpBottom,16/S);
    if FHeadCategory=0 then Color:=HatColors[I]else Color:=HairColors[I];
    B.CustomColorNormal:=Vector4(Color,1);B.CustomColorFocused:=Vector4(Color*0.8+Vector3(0.2,0.2,0.2),1);
    B.CustomColorPressed:=B.CustomColorFocused;
  end;
  for I:=0 to High(FHeadViews)do begin
    B:=FHeadViews[I];B.Width:=90/S;B.Height:=32/S;B.FontSize:=14/S;
    B.Anchor(hpMiddle,(I-1)*98/S);B.Anchor(vpBottom,38/S);B.Exists:=FHairOverlay.Exists;
  end;
  FHeadHint.FontSize:=12/S;FHeadHint.Anchor(hpMiddle);FHeadHint.Anchor(vpBottom,14/S);FHeadHint.Exists:=FHairOverlay.Exists;
end;

procedure TBikeFitPage.ClickHeadCategory(Sender:TObject);
begin
  FHeadCategory:=TMenuButton(Sender).Tag;LayoutHairList;ScrollHeadSelection;
  if FHeadCategory=1 then FHeadYaw:=145 else FHeadYaw:=15;
  UpdateHeadCamera(True);
end;
procedure TBikeFitPage.ScrollHeadSelection;
var I:Integer;Id:String;S:Single;
begin
  Id:=UserPreference(HeadKeys[FHeadCategory],HeadDefaults[FHeadCategory]);
  if FHeadCategory=1 then Id:=RiderHairStyleId(ParseRiderHairStyle(Id));
  S:=Max(0.65,Min(1,UIScale));FHairScroll.Scroll:=0;
  for I:=0 to HeadOptionCount(FHeadCategory)-1 do if Id=HeadOptionId(FHeadCategory,I)then begin
    FHairScroll.Scroll:=Max(0,(I-2)*94/S);Break;
  end;
end;
procedure TBikeFitPage.ClickHeadView(Sender:TObject);
begin FHeadYaw:=TMenuButton(Sender).Tag*90;UpdateHeadCamera(True) end;
procedure TBikeFitPage.ClickHeadColor(Sender:TObject);
var C:TVector4;
begin
  C:=TMenuButton(Sender).CustomColorNormal;
  if FHeadCategory=0 then ApplyHelmetColorLive(Vector3(C.X,C.Y,C.Z),True)
  else ApplyClothSlot(csHair,Vector3(C.X,C.Y,C.Z),True);
end;
procedure TBikeFitPage.UpdateHeadCamera(Reset:Boolean);
var M:TMatrix4;HeadCenter,P,D,U,Offset:TVector3;Dist,Yaw:Single;
begin
  if Reset then FHeadCameraReady:=False;
  if (FResultBike=nil)or(FResultBike.TripoRider=nil)or not FResultBike.TripoRider.Loaded then Exit;
  Reset:=Reset or not FHeadCameraReady;
  M:=FResultBike.TripoRider.HeadWorldFrame;
  Offset:=Vector3(0,0.055,0);Dist:=0.62;
  if FHeadCategory=1 then begin Offset.Y:=-0.060;Dist:=0.90 end;
  if(FHeadCategory=1)and(FResultBike.TripoRider.HairStyle=rhsLongBraid)then begin Offset.Y:=-0.13;Dist:=1.05 end;
  HeadCenter:=M.MultPoint(Offset);
  FNavResult.ModelBox:=Box3D(HeadCenter-Vector3(0.30,0.36,0.30),HeadCenter+Vector3(0.30,0.36,0.30));
  if Reset then begin
    Yaw:=DegToRad(FHeadYaw);
    P:=HeadCenter+M.MultDirection(Vector3(Sin(Yaw)*Dist,0.03,Cos(Yaw)*Dist));
    D:=(HeadCenter-P).Normalize;U:=M.MultDirection(Vector3(0,1,0)).Normalize;
    FVpResult.Camera.SetWorldView(P,D,U);
  end else begin
    FVpResult.Camera.GetWorldView(P,D,U);FVpResult.Camera.SetWorldView(P+HeadCenter-FHeadLastCenter,D,U);
  end;
  FHeadLastCenter:=HeadCenter;
  FHeadCameraReady:=True;
end;

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
  FAppearanceRows.ScrollArea.InsertFront(FDyeStrip);

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
    B.Name:='AppearanceColor'+IntToStr(I);
    BindUiText(B, DyeSlotTitle(I));
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
    B.Name:='AppearanceSwatch'+IntToStr(I);
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
  FDyeTitle.Caption:=UiText(DyeSlotTitle(Idx));
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
const WardrobeColorSlots:array[0..4]of Integer=(0,1,0,3,9);
var
  I: Integer;
  C: TVector4;
  On_: Boolean;
begin
  for I := 0 to 9 do
  begin
    if FDyeBtns[I] = nil then Continue;
    BindUiText(FDyeBtns[I],DyeSlotTitle(I));
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
  if FWardrobePanel<>nil then
    for I:=0 to High(WardrobeColorSlots)do
      if FDyeBtns[WardrobeColorSlots[I]]<>nil then
        FWardrobePanel.SetColor(I,FDyeBtns[WardrobeColorSlots[I]].CustomColorNormal);
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
begin
  { Keep the preset used by asynchronous clothing reloads and the live
    material in sync. The wardrobe also supports live tint on native skin. }
  if FResultBike = nil then Exit;
  for S := Low(TClothSlot) to High(TClothSlot) do
    FResultBike.SetRiderClothColorLive(S,FDyeColor[S],FDyeOn[S]);
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
  if FResultBike = nil then Exit;
  { Keep the instance preset and live material together: changing body/fit
    reapplies the preset, so tinting only the current rider lost this color. }
  FResultBike.SetHeadwearColorLive(FHelmetC,FHelmetOn);
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
  ApplyHairStyle;
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
  FSection:=(Sender as TMenuButton).Tag;ClosePopup;CloseDyePopup;CloseHairList(nil);LayoutSections;
end;

function TBikeFitPage.HandleBack:Boolean;
begin
  Result:=True;
  if(FHairOverlay<>nil)and FHairOverlay.Exists then begin CloseHairList(nil);Exit;end;
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
          C.Controls[J].Anchor(hpRight,-40/S)
        else TCastleLabel(C.Controls[J]).MaxWidth:=Max(50/S,C.EffectiveWidth-164/S);
      end else if C.Controls[J] is TCastleButton then begin
        TCastleButton(C.Controls[J]).FontScale:=1;TCastleButton(C.Controls[J]).FontSize:=18/S;
        C.Controls[J].Width:=34/S;C.Controls[J].Height:=28/S;
        if C.Controls[J]=B then C.Controls[J].Anchor(hpRight,-118/S);
      end;
  end;
begin
  if(FSectionButtons[2]=nil)or(FDyeStrip=nil)or(FHairBox=nil)or(FBottomRow.EffectiveWidth<=0)then Exit;
  S:=Max(0.65,Min(1,UIScale));W:=Min(420/S,FBottomRow.EffectiveWidth*0.46);
  if FMainHost<>nil then FMainHost.Border.Bottom:=42/S;
  if FLabelStatus<>nil then begin
    FLabelStatus.CustomFont:=MenuFont;FLabelStatus.FontScale:=1;
    FLabelStatus.FontSize:=12/S;FLabelStatus.Color:=MenuMuted;
    FLabelStatus.Anchor(vpBottom,12/S);
  end;
  if FBottomRow.EffectiveWidth<720/S then W:=FBottomRow.EffectiveWidth;
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
  FColResult.WidthFraction:=0;
  if FBottomRow.EffectiveWidth<720/S then begin
    FColParams.HeightFraction:=0;FColParams.Height:=620/S;FColParams.Anchor(vpTop);
    FColResult.HeightFraction:=0;FColResult.Height:=360/S;
    FColResult.Width:=W;FColResult.Anchor(hpLeft);FColResult.Anchor(vpTop,-630/S);
  end else begin
    FColParams.HeightFraction:=1;FColParams.Anchor(vpTop);
    FColResult.HeightFraction:=1;FColResult.Width:=FBottomRow.EffectiveWidth-W;
    FColResult.Anchor(hpRight);FColResult.Anchor(vpTop);
  end;
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
  FBtnAutoFit.Exists:=FSection=0;FBtnAutoFit.Width:=W-24/S;FBtnAutoFit.Height:=34/S;
  FBtnAutoFit.FontScale:=1;FBtnAutoFit.FontSize:=15/S;
  FBtnAutoFit.Anchor(hpMiddle);FBtnAutoFit.Anchor(vpTop,-178/S);
  Row(FBtnSeatHDown,0,0,224);Row(FBtnSeatODown,0,1,224);
  Row(FBtnSpacersDown,0,2,224);Row(FBtnStemDown,0,3,224);
  FBodyRows.Exists:=FSection=1;
  FBodyRows.Border.Top:=92/S;FBodyRows.Border.Bottom:=158/S;
  FBodyRows.ScrollArea.Height:=350/S;
  Row(FBtnSexDown,1,0,4);Row(FBtnHeightDown,1,1,4);
  Row(FBtnBulkDown,1,2,4);Row(FBtnBellyDown,1,3,4);
  Row(FBtnInseamDown,1,4,4);Row(FBtnArmDown,1,5,4);
  Row(FBtnHeadDown,1,6,4);Row(FBtnKneeDown,1,7,4);Row(FBtnAnkleDown,1,8,4);
  for I:=0 to High(FValueButtons)do if FValueButtons[I]<>nil then begin
    FValueButtons[I].Width:=74/S;FValueButtons[I].Height:=28/S;FValueButtons[I].FontScale:=1;
    FValueButtons[I].FontSize:=14/S;FValueButtons[I].Anchor(hpRight,-38/S);
  end;
  FRiderParams.Width:=200/S;FRiderParams.Height:=32/S;FRiderParams.FontScale:=1;FRiderParams.FontSize:=14/S;
  FRiderParams.Exists:=FSection=1;FRiderParams.Anchor(vpBottom,105/S);
  FCadenceControls.WidthFraction:=0.5;FCadenceControls.Anchor(hpLeft,0);
  FCadenceControls.Anchor(vpBottom,8);FCadenceControls.Height:=86/S;
  FEffortControls.WidthFraction:=0.5;FEffortControls.Anchor(hpRight,0);
  FEffortControls.Anchor(vpBottom,8);FEffortControls.Height:=86/S;
  if FCadenceCaption<>nil then begin
    FCadenceCaption.FontScale:=1;FCadenceCaption.FontSize:=14/S;
    FCadenceCaption.MaxWidth:=Max(80/S,W*0.5-40/S);
  end;
  if FEffortCaption<>nil then begin
    FEffortCaption.FontScale:=1;FEffortCaption.FontSize:=14/S;
    FEffortCaption.MaxWidth:=Max(80/S,W*0.5-40/S);
  end;
  FBtnCadenceDown.Width:=34/S;FBtnCadenceDown.Height:=28/S;
  FBtnCadenceUp.Width:=34/S;FBtnCadenceUp.Height:=28/S;
  FBtnCadenceDown.FontScale:=1;FBtnCadenceDown.FontSize:=18/S;
  FBtnCadenceUp.FontScale:=1;FBtnCadenceUp.FontSize:=18/S;
  FLblCadence.FontScale:=1;FLblCadence.FontSize:=16/S;
  FBtnEffortDown.Width:=34/S;FBtnEffortDown.Height:=28/S;
  FBtnEffortUp.Width:=34/S;FBtnEffortUp.Height:=28/S;
  FBtnEffortDown.FontScale:=1;FBtnEffortDown.FontSize:=18/S;
  FBtnEffortUp.FontScale:=1;FBtnEffortUp.FontSize:=18/S;
  FLblEffort.FontScale:=1;FLblEffort.FontSize:=16/S;
  FAppearanceRows.Exists:=FSection=2;
  FAppearanceRows.Border.Top:=92/S;FAppearanceRows.Border.Bottom:=106/S;
  FAppearanceRows.ScrollArea.Height:=744/S;
  FWardrobePanel.WidthFraction:=0;FWardrobePanel.Width:=W-20;
  FWardrobePanel.Anchor(hpMiddle);FWardrobePanel.Anchor(vpTop,-116/S);FWardrobePanel.Resize;
  FHairBox.Width:=W-20;FHairBox.Height:=104/S;
  FHairTitle.FontScale:=1;FHairTitle.FontSize:=16/S;
  FHairSelect.Width:=W-28;FHairSelect.Height:=72/S;
  FHairSelect.FontScale:=1;FHairSelect.FontSize:=15/S;
  FHairSelect.PaddingHorizontal:=92/S;
  FHairPreview.Width:=72/S;FHairPreview.Height:=54/S;FHairPreview.Anchor(hpLeft,8/S);
  FHairSelect.Caption:=MenuSummary(UiText('Head editor'),FHairSelect.Font,
    (FHairSelect.Width-122/S)*UIScale,2);
  FDyeStrip.Width:=W-20;FDyeStrip.Height:=266/S;
  FDyeStrip.Anchor(vpTop,-470/S);
  for I:=0 to High(FDyeBtns)do begin
    FDyeBtns[I].Width:=(W-40)/2;FDyeBtns[I].Height:=40/S;
    FDyeBtns[I].FontScale:=1;FDyeBtns[I].FontSize:=14/S;
    FDyeBtns[I].Anchor(hpLeft,6+(I mod 2)*(W-28)/2);
    FDyeBtns[I].Anchor(vpTop,-(34+(I div 2)*44)/S);
  end;
  if FOnFootPreview then begin
    FSectionButtons[0].Exists:=False;
    FSectionButtons[1].Width:=(W-24)/2;FSectionButtons[1].Anchor(hpLeft,8);
    FSectionButtons[2].Width:=(W-24)/2;FSectionButtons[2].Anchor(hpLeft,W/2+4);
    FBikeControls.Exists:=False;FEffortControls.Exists:=False;
    FFitOverlay.Exists:=False;
    FBtnKneeDown.Parent.Exists:=False;FBtnAnkleDown.Parent.Exists:=False;
    FBodyRows.ScrollArea.Height:=278/S;
    FDyeBtns[7].Exists:=False;FDyeBtns[8].Exists:=False;
  end else begin
    FSectionButtons[0].Exists:=True;FDyeBtns[7].Exists:=True;FDyeBtns[8].Exists:=True;
  end;
  LayoutHairList;
end;

procedure TBikeFitPage.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited;
  if (not Exists) or FLoadingPreview then Exit;

  FLoadingPreview := True;
  try
    PumpResultRiderLoad;
    if FDirtyResult then ReloadResultPreview;
    if FAutoFitPending and(FWantRiderPath='')then RunAutoFit;
  finally
    FLoadingPreview := False;
    if FReleasePreviewPending then
    begin
      FReleasePreviewPending := False;
      PageHidden;
    end;
  end;
  if not Exists then Exit;
  FBtnAutoFit.Enabled:=(FResultBike<>nil)and FResultBike.HasTripoRider and
    not FAutoFitPending and not FDirtyResult and(FWantRiderPath='')and(FSizeNames.Count>0);
  if FLiveSettingsDirty then begin
    FFitSaveDelay:=FFitSaveDelay-SecondsPassed;
    if FFitSaveDelay<=0 then begin FFitSaveDelay:=5;ClickApply(nil);end;
  end;
  if FPosePrev<>nil then begin
    FPosePrev.Exists:=not FOnFootPreview and not FLiveRide and not FHairOverlay.Exists;
    FPoseNext.Exists:=FPosePrev.Exists;FPoseToggle.Exists:=FPosePrev.Exists;
    FLblPose.Exists:=not FOnFootPreview and not FHairOverlay.Exists;
  end;
  if FLiveRide then
  begin
    if FOnFootPreview then begin FWalkPreviewSpeed:=Abs(ViewPlay.RideSpeed);UpdateLabels;Exit end;
    if (Round(FCadenceRpm) <> Round(ViewPlay.RideCadence)) or
       (Round(FLastLiveEffortPct) <> Round(CurrentEffortPct)) then
    begin
      FCadenceRpm := ViewPlay.RideCadence;
      FLastLiveEffortPct := CurrentEffortPct;
      UpdateLabels;
    end;
    Exit;
  end;
  if FResultBike <> nil then
  begin
    if FPreviewAnimationPaused then Exit;
    if FOnFootPreview then begin
      FResultBike.AnimateOnFoot(SecondsPassed,FWalkPreviewSpeed,0);
      if FResultBike.HasTripoRider and not FOnFootFramed then begin
        FOnFootFramed:=True;FitCameraToItems(FVpResult);
      end;
      Exit;
    end;
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

procedure TBikeFitPage.McpAnimation(AParams,AResult:TJSONObject);
var I,Frames:Integer;Hz,Phase:Single;
begin
  if FLiveRide then raise Exception.Create('Use ride simulation controls during an activity');
  if not FOnFootPreview then raise Exception.Create('Walking preview required');
  if (FResultBike=nil)or not FResultBike.HasTripoRider or(FWantRiderPath<>'')then
    raise Exception.Create('Wait for the avatar to finish loading');
  FPreviewAnimationPaused:=AParams.Get('paused',True);
  FWalkPreviewSpeed:=EnsureRange(AParams.Get('speed',Double(FWalkPreviewSpeed)),0.0,8.0);
  Frames:=EnsureRange(AParams.Get('frames',0),0,600);
  Hz:=EnsureRange(AParams.Get('fps',60.0),10.0,240.0);
  Phase:=AParams.Get('phase',-1.0);
  if Phase>=0 then FResultBike.AnimateOnFoot(0,FWalkPreviewSpeed,0,0,Frac(Phase));
  for I:=1 to Frames do FResultBike.AnimateOnFoot(1/Hz,FWalkPreviewSpeed,0);
  UpdateLabels;
  McpFillStatus(AResult);
  AResult.Add('animation_paused',FPreviewAnimationPaused);
end;

procedure TBikeFitPage.ClickCadenceDown(Sender: TObject);
begin
  if FOnFootPreview then begin FWalkPreviewSpeed:=Max(0,FWalkPreviewSpeed-0.2);UpdateLabels;Exit end;
  if FLiveRide then Exit;
  FCadenceRpm := Max(0, FCadenceRpm - 10);
  ApplyPreviewAnimation;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickCadenceUp(Sender: TObject);
begin
  if FOnFootPreview then begin FWalkPreviewSpeed:=Min(6,FWalkPreviewSpeed+0.2);UpdateLabels;Exit end;
  if FLiveRide then Exit;
  FCadenceRpm := Min(160, FCadenceRpm + 10);
  ApplyPreviewAnimation;
  UpdateLabels;
end;

function TBikeFitPage.CurrentEffortPct: Single;
begin
  if FLiveRide and (FResultBike <> nil) then
    Result := FResultBike.RiderEffortTarget * 100
  else
    Result := FPreviewEffortPct;
end;

procedure TBikeFitPage.ClickEffortDown(Sender: TObject);
begin
  if FLiveRide then Exit;
  FPreviewEffortPct := Max(0, FPreviewEffortPct - 5);
  ApplyPreviewAnimation;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickEffortUp(Sender: TObject);
begin
  if FLiveRide then Exit;
  FPreviewEffortPct := Min(200, FPreviewEffortPct + 5);
  ApplyPreviewAnimation;
  UpdateLabels;
end;

procedure TBikeFitPage.NudgeFit(var AValue: Single; ADelta, AMin, AMax: Single);
begin
  FAutoFitStatus:=0;
  AValue := EnsureRange(AValue + ADelta, AMin, AMax);
  FFitInited := True;
  ApplyFitToPreview;
  ApplyPreviewAnimation;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickAutoFit(Sender:TObject);
begin
  if FLoadingPreview or FDirtyResult or FAutoFitPending or(FWantRiderPath<>'')or
    (FResultBike=nil)or not FResultBike.HasTripoRider or(FSizeNames.Count=0)then Exit;
  ClosePopup;CancelValue(nil);
  FAutoFitStatus:=0;FAutoFitPending:=True;
  FBtnAutoFit.Enabled:=False;BindUiText(FBtnAutoFit,'Fitting bicycle...');
end;

procedure TBikeFitPage.RunAutoFit;
var Fit:TAutomaticBikeFit;T0:QWord;
begin
  FAutoFitPending:=False;T0:=GetTickCount64;
  try
    if not FitCatalogBike(FResultBike,FGeoList,FSizeNames,FModelInfo,CurrentBody,Fit)then
      raise Exception.Create('No usable frame geometry for automatic fit');
    FSelSize:=Fit.SizeIndex;
    FFitSeatExt:=Fit.SeatExt;FFitSaddleOff:=Fit.SaddleOffset;
    FFitSpacers:=Fit.Spacers;FFitStem:=Fit.Stem;FFitInited:=True;
    ReapplyColorsAfterBuild;
    ApplyPreviewAnimation;
    if FLiveRide then ViewPlay.BikeFitChanged else FitCameraToItems(FVpResult);
    FLiveSettingsDirty:=True;
    ClickApply(nil);
    if not FLiveSettingsDirty then begin
      FAutoFitStatus:=1;if Fit.Limited then FAutoFitStatus:=2;
    end else FAutoFitStatus:=4;
    Logger.Info(Format('[BikeFit] automatic size=%s seat=%.1f offset=%.1f spacers=%.0f stem=%.0f score=%.2f time=%d ms',
      [CurrentSizeName,FFitSeatExt,FFitSaddleOff,FFitSpacers,FFitStem,Fit.CockpitScore,GetTickCount64-T0]));
  except
    on E:Exception do begin
      FAutoFitStatus:=3;Logger.Warning('[BikeFit] automatic fit failed: '+E.Message);
    end;
  end;
  BindUiText(FBtnAutoFit,'Fit bike to rider');UpdateLabels;
end;

procedure TBikeFitPage.McpAutoFit;
begin ClickAutoFit(nil) end;

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

function TBikeFitPage.CurrentBody:TRiderBodyParameters;
begin
  Result:=DefaultRiderBody(FFitSex);
  Result.HeightCm:=FFitHeightCm;Result.InseamCm:=FFitInseamCm;
  Result.WeightKg:=FFitWeightKg;Result.Composition:=FFitComposition;
  Result.ArmLengthCm:=FFitArmCm;Result.HeadShape:=FFitHead;
  Result:=NormalizeRiderBody(Result);
end;

procedure TBikeFitPage.LoadBodyFields;
var P:TRiderBodyParameters;
begin
  P:=AvatarBodyParameters;
  FFitSex:=P.Sex;FFitHeightCm:=P.HeightCm;FFitInseamCm:=P.InseamCm;
  FFitWeightKg:=P.WeightKg;FFitComposition:=P.Composition;
  FFitArmCm:=P.ArmLengthCm;FFitHead:=P.HeadShape;
end;

procedure TBikeFitPage.SeedRiderShapeFromBike;
begin
  { A model reload must not replace physical measurements by its native size. }
  if FFitHeightCm<130 then LoadBodyFields;
end;

procedure TBikeFitPage.ClickBodyParameter(Sender:TObject);
var TagValue,Direction:Integer;
begin
  TagValue:=TComponent(Sender).Tag;Direction:=Sign(TagValue);
  case Abs(TagValue) of
    1:FFitSex:=EnsureRange(FFitSex+Direction*0.05,0,1);
    2:FFitArmCm:=EnsureRange(RiderBodyArmCm(CurrentBody)+Direction,FFitHeightCm*0.24,FFitHeightCm*0.40);
    3:FFitHead:=EnsureRange(FFitHead+Direction*0.05,0,1);
  end;
  ApplyRiderShapeToPreview;UpdateLabels;
end;

procedure TBikeFitPage.ApplyRiderShapeToPreview;
begin
  if FResultBike=nil then Exit;
  FAutoFitStatus:=0;
  SeedRiderShapeFromBike;
  FResultBike.BodyParameters:=CurrentBody;
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
      FLblReach.Caption := Format(UiText('Reach  %0.0f mm'), [ReachMm])
    else
      BindUiText(FLblReach, 'Reach  —');
  end;
  if FLblStack <> nil then
  begin
    if StackMm > 0 then
      FLblStack.Caption := Format(UiText('Stack  %0.0f mm'), [StackMm])
    else
      BindUiText(FLblStack, 'Stack  —');
  end;
end;

procedure TBikeFitPage.ClickSeatHDown(Sender: TObject);
begin
  NudgeFit(FFitSeatExt, -5, 10, 400);
end;

procedure TBikeFitPage.ClickSeatHUp(Sender: TObject);
begin
  NudgeFit(FFitSeatExt, 5, 10, 400);
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
  FFitHeightCm := EnsureRange(FFitHeightCm - 1, 130, 220);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickHeightUp(Sender: TObject);
begin
  SeedRiderShapeFromBike;
  FFitHeightCm := EnsureRange(FFitHeightCm + 1, 130, 220);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickInseamDown(Sender: TObject);
begin
  SeedRiderShapeFromBike;
  FFitInseamCm := EnsureRange(RiderBodyInseamCm(CurrentBody) - 1, FFitHeightCm*0.36, FFitHeightCm*0.58);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickInseamUp(Sender: TObject);
begin
  SeedRiderShapeFromBike;
  FFitInseamCm := EnsureRange(RiderBodyInseamCm(CurrentBody) + 1, FFitHeightCm*0.36, FFitHeightCm*0.58);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickBulkDown(Sender: TObject);
begin
  FFitWeightKg := EnsureRange(FFitWeightKg - 1, 35, 180);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickBulkUp(Sender: TObject);
begin
  FFitWeightKg := EnsureRange(FFitWeightKg + 1, 35, 180);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickBellyDown(Sender: TObject);
begin
  FFitComposition := EnsureRange(FFitComposition - 0.05, 0, 1);
  FFitInited := True;
  ApplyRiderShapeToPreview;
  UpdateLabels;
end;

procedure TBikeFitPage.ClickBellyUp(Sender: TObject);
begin
  FFitComposition := EnsureRange(FFitComposition + 0.05, 0, 1);
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
  LoadBodyFields;
  ApplyRiderShapeToPreview;
  if FResultBike <> nil then
    RequestResultRider(CurrentRiderPath)
  else
    FDirtyResult := True;
  UpdateLabels;
end;

procedure TBikeFitPage.McpBody(AParams,AResult:TJSONObject);
begin
  SaveAvatarBody(ReadRiderBody(AParams,CurrentBody));
  LoadBodyFields;ApplyRiderShapeToPreview;UpdateLabels;
  McpFillStatus(AResult);
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
    else if (P = 'effort') or (P = 'load') then
      if Up then ClickEffortUp(nil) else ClickEffortDown(nil)
    else
      raise Exception.Create('unknown fit param "' + AParam + '"');
  end;
end;

procedure TBikeFitPage.McpFillStatus(AResult: TJSONObject);
var FaceState, HairState: TJSONObject;
begin
  if FResultBike<>nil then WardrobeState(FResultBike.TripoRider,AResult)
  else WardrobeState(nil,AResult);
  AResult.Add('auto_fit_pending',FAutoFitPending);
  AResult.Add('auto_fit_status',FAutoFitStatus);
  if(FSelBike>=0)and(FSelBike<FBikePaths.Count)then
    AResult.Add('bike_path',FBikePaths[FSelBike]);
  AResult.Add('bike_size',CurrentSizeName);
  AResult.Add('hair_style',UserPreference('rider_hair_style','short'));
  AResult.Add('head_editor_open',(FHairOverlay<>nil)and FHairOverlay.Exists);
  AResult.Add('head_category',FHeadCategory);
  AResult.Add('preview_loading',FLoadingPreview or FDirtyResult or (FWantRiderPath<>''));
  AResult.Add('rider_loaded',(FResultBike<>nil)and(FResultBike.TripoRider<>nil)and FResultBike.TripoRider.Loaded);
  if(FResultBike<>nil)and(FResultBike.TripoRider<>nil)then
    AResult.Add('applied_hair_style',RiderHairStyleId(FResultBike.TripoRider.HairStyle));
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
  AResult.Add('body',WriteRiderBody(CurrentBody));
  if (FResultBike<>nil) and (FResultBike.TripoRider<>nil) then
    AResult.Add('shared_geometry',FResultBike.TripoRider.HasParametricBody);
  AResult.Add('knee_flare', FFitKneeFlare);
  AResult.Add('ankle_flex', FFitAnkleFlex);
  AResult.Add('seat_mm', FFitSeatExt);
  AResult.Add('offset_mm', FFitSaddleOff);
  AResult.Add('spacers_mm', FFitSpacers);
  AResult.Add('stem_mm', FFitStem);
  AResult.Add('cadence', FCadenceRpm);
  AResult.Add('effort_pct', CurrentEffortPct);
  AResult.Add('preview_effort_pct', FPreviewEffortPct);
  AResult.Add('preview_controls_enabled', not FLiveRide);
  AResult.Add('has_result', FResultBike <> nil);
  AResult.Add('live_ride', FLiveRide);
  if FResultBike <> nil then
  begin
    AResult.Add('gpu_animation', FResultBike.GpuAnim);
    AResult.Add('fixed_gear', FResultBike.IsFixedGear);
    AResult.Add('drive_metres_per_crank_rev', FResultBike.DriveMetresPerCrankRevolution);
    AResult.Add('visual_cadence', FResultBike.RiderCadenceRpm);
    if (not FLoadingPreview) and (FResultBike.TripoRider <> nil) and
       FResultBike.TripoRider.Loaded then
    begin
      AResult.Add('motion', FResultBike.RiderMotionDebugJson);
      HairState := TJSONObject.Create;
      FResultBike.TripoRider.HairDebugJson(HairState);
      AResult.Add('hair', HairState);
      if FResultBike.TripoRider.Face <> nil then
      begin
        FaceState := TJSONObject.Create;
        FResultBike.TripoRider.Face.DebugJson(FaceState);
        AResult.Add('face', FaceState);
      end;
    end;
  end;
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
    Settings.SetGender(Settings.GetGender); { preserve selected preset label }
    Settings.SetFitAdjustments(FFitSeatExt, FFitSaddleOff, FFitSpacers, FFitStem);
    Settings.SetRiderShape(FFitHeightCm, FFitInseamCm, 0, 0,
      FFitKneeFlare, FFitAnkleFlex);
  finally
    Saved := Settings.EndUpdate;
  end;
  if not Saved then
  begin
    BindUiText(FLabelStatus, 'Could not save settings. Please try again.');
    Exit;
  end;
  SaveAvatarBody(CurrentBody);
  FLiveSettingsDirty := False;
  if FLiveRide then
    BindTravelText(FLabelStatus, 'Saved and applied to the current ride.')
  else
    BindTravelText(FLabelStatus, 'Saved — applies to the next ride.');
  Logger.Info(Format('[BikeFit] apply bike=%s size=%s rider=%s fit seat=%0.0f off=%0.0f sp=%0.0f stem=%0.0f h=%0.0f in=%0.0f bulk=%0.2f belly=%0.2f knee=%0.2f ankle=%0.0f',
    [Settings.SelectedBikeJson, Settings.SelectedBikeSize,
     Settings.SelectedRiderGlb, FFitSeatExt, FFitSaddleOff, FFitSpacers, FFitStem,
     FFitHeightCm, FFitInseamCm, FFitWeightKg, FFitComposition,
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
    4:V:=FFitHeightCm;5:V:=FFitInseamCm;6:V:=FFitWeightKg;7:V:=FFitComposition*100;
    10:V:=FFitSex*100;11:V:=FFitArmCm;12:V:=FFitHead*100;
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
    0:FFitSeatExt:=EnsureRange(V,10,400);1:FFitSaddleOff:=EnsureRange(V,-50,50);
    2:FFitSpacers:=EnsureRange(V,0,50);3:FFitStem:=EnsureRange(V,60,140);
    4:FFitHeightCm:=EnsureRange(V,130,220);5:FFitInseamCm:=V;
    6:FFitWeightKg:=EnsureRange(V,35,180);7:FFitComposition:=EnsureRange(V/100,0,1);
    10:FFitSex:=EnsureRange(V/100,0,1);11:FFitArmCm:=V;12:FFitHead:=EnsureRange(V/100,0,1);
    8:FFitKneeFlare:=EnsureRange(V,-0.5,0.5);9:FFitAnkleFlex:=EnsureRange(V,0,40);
  end;
  FFitInited:=True;ApplyFitToPreview;UpdateLabels;LiveFitChanged;CancelValue(nil);
end;

end.
