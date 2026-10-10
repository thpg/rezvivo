unit GameGraphicsUI;

{$mode objfpc}{$H+}

interface

uses Classes, CastleUIControls, CastleControls, GameMenuTheme, GameGraphicsOptions,
  GameGraphicsAuto, GameGraphicsBenchmarkScene;

type
  TGraphicsPreview = class(TCastleUserInterface)
  private
    FScene: TGraphicsBenchmarkScene;
    FTitle, FHint: TCastleLabel;
    FRevision: Cardinal;
    FSuspended: Boolean;
    FToggle: TMenuButton;
    FMode: Integer;
    FWindow: TCastleView;
    FIsWindow: Boolean;
    function GetExpanded: Boolean;
    procedure TogglePreview(Sender:TObject);
  public
    constructor Create(AOwner:TComponent); override;
    procedure ReleaseScene;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean); override;
    property Expanded:Boolean read GetExpanded;
    property Suspended:Boolean read FSuspended write FSuspended;
  end;

  TGraphicsPanel = class(TCastleUserInterface)
  private
    FTitle, FIntro: TCastleLabel;
    FAutoButton: TMenuButton;
    FPresetFlow: TMenuFlow;
    FPresetButtons: array[TGraphicsPreset] of TMenuButton;
    FPresetHint: TCastleLabel;
    procedure ClickPreset(Sender:TObject);
  private
    FAutoHint, FAutoResult: TCastleLabel;
    FAutoRun: TGraphicsAutoRun;
    FRows: array[TGraphicsOption] of TCastleUserInterface;
    FLabels, FHints: array[TGraphicsOption] of TCastleLabel;
    FChoices: array[TGraphicsOption] of TMenuFlow;
    FButtons: array[TGraphicsOption] of array of TMenuButton;
    FRevision: Cardinal;
    FPreview: TGraphicsPreview;
    procedure ClickChoice(Sender: TObject);
    procedure ClickAuto(Sender: TObject);
    procedure LanguageChanged(Sender:TObject);
    procedure Arrange;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Refresh;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    property Preview:TGraphicsPreview read FPreview write FPreview;
  end;

implementation

uses CastleKeysMouse, Math, SysUtils, AppSettings, UiTranslations, CastleColors, Osm3dVegetationQuality;

type
  TGraphicsPreviewWindow=class(TCastleView)
  private FPreview:TGraphicsPreview;
  public
    constructor Create(AOwner:TComponent);override;
    procedure Stop;override;
    function Press(const Event:TInputPressRelease):Boolean;override;
  end;
constructor TGraphicsPreviewWindow.Create(AOwner:TComponent);
var Background:TMenuPanel;
begin
  inherited;
  Background:=TMenuPanel.Create(Self);Background.FullSize:=True;
  Background.Color:=MenuBackground;InsertFront(Background);
  FPreview:=TGraphicsPreview.Create(Self);FPreview.FullSize:=True;
  FPreview.FIsWindow:=True;FPreview.FMode:=1;
  BindUiText(FPreview.FToggle,'Back');FPreview.FToggle.Anchor(hpLeft,12);
  FPreview.FToggle.Anchor(vpTop,-4);InsertFront(FPreview);
end;
procedure TGraphicsPreviewWindow.Stop;
begin FPreview.ReleaseScene;inherited end;
function TGraphicsPreviewWindow.Press(const Event:TInputPressRelease):Boolean;
begin
  if Event.IsKey(keyEscape) then begin Container.PopView(Self);Exit(True) end;
  Result:=inherited;
end;

constructor TGraphicsPreview.Create(AOwner:TComponent);
begin
  inherited;
  Name:='GraphicsPreview';
  FTitle:=TMenuLabel.Create(Self);BindUiText(FTitle,'Live preview');
  FToggle:=TMenuButton.Create(Self);FToggle.Name:='ToggleGraphicsPreview';
  FToggle.AutoIcon:=False;FToggle.FontSize:=16;FToggle.MinHeight:=44;
  FToggle.OnClick:=@TogglePreview;FToggle.Anchor(hpLeft);FToggle.Anchor(vpTop);
  BindUiText(FToggle,'Live preview');InsertFront(FToggle);
  FTitle.Exists:=False;
  FTitle.FontSize:=22;FTitle.Anchor(hpLeft);FTitle.Anchor(vpTop);InsertFront(FTitle);
  FHint:=TMenuLabel.Create(Self);
  BindUiText(FHint,'Preview FPS depends on its size. Auto tests the same scene at full window size.');
  FHint.FontSize:=14;FHint.Color:=MenuMuted;
  FHint.Anchor(hpLeft);FHint.Anchor(vpBottom);InsertFront(FHint);
end;

function TGraphicsPreview.GetExpanded:Boolean;
begin
  Result:=FMode=1;
  {$ifndef ANDROID}
  if (FMode=0) and (Container<>nil) then
    Result:=(Container.UnscaledWidth>=1180) and (Container.UnscaledHeight>=690);
  {$endif}
end;
procedure TGraphicsPreview.TogglePreview(Sender:TObject);
begin
  if FIsWindow then begin Container.PopView(FWindow);Exit end;
  if (Container<>nil) and (Container.UnscaledHeight<600) then begin
    if FWindow=nil then begin
      FWindow:=TGraphicsPreviewWindow.Create(Self);
      TGraphicsPreviewWindow(FWindow).FPreview.FWindow:=FWindow;
    end;
    Container.PushView(FWindow);Exit;
  end;
  if GetExpanded then FMode:=2 else FMode:=1;
  if not GetExpanded then ReleaseScene;
end;

procedure TGraphicsPreview.ReleaseScene;
begin
  FreeAndNil(FScene);
end;

procedure TGraphicsPreview.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var Values:TGraphicsValues;O:TGraphicsOption;
begin
  inherited;
  if FSuspended then Exit;
  FHint.Exists:=GetExpanded;
  SelectMenuButton(FToggle,GetExpanded);
  if not GetExpanded then begin ReleaseScene;Exit end;
  FHint.MaxWidth:=Max(180,EffectiveWidth);
  if FScene=nil then begin
    FScene:=TGraphicsBenchmarkScene.Create(Self);
    FScene.Name:='GraphicsPreviewScene';
    InsertBack(FScene);FRevision:=Settings.GraphicsRevision-1;
  end;
  FScene.Border.Top:=52;FScene.Border.Bottom:=FHint.EffectiveHeight+10;
  if FRevision<>Settings.GraphicsRevision then begin
    for O:=Low(O) to High(O) do Values[O]:=Settings.GetGraphicsOption(Ord(O));
    FScene.ApplyProfile(Values);FRevision:=Settings.GraphicsRevision;
  end;
end;

constructor TGraphicsPanel.Create(AOwner: TComponent);
var O: TGraphicsOption; I: Integer; B: TMenuButton; P:TGraphicsPreset;
begin
  inherited;
  Name := 'GraphicsSettings';
  Width := 800;
  FTitle := TMenuLabel.Create(Self);
  BindUiText(FTitle, 'Graphics');
  FTitle.FontSize := 26;
  FTitle.Anchor(hpLeft); FTitle.Anchor(vpTop);
  InsertFront(FTitle);
  FIntro := TMenuLabel.Create(Self);
  BindUiText(FIntro, 'Saved automatically on this computer. Changes apply immediately unless noted.');
  FIntro.FontSize := 15; FIntro.Color := MenuMuted;
  FIntro.Anchor(hpLeft); FIntro.Anchor(vpTop, -36);
  InsertFront(FIntro);
  FPresetFlow:=TMenuFlow.Create(Self);FPresetFlow.WidthFraction:=0;
  FPresetFlow.Spacing:=8;InsertFront(FPresetFlow);
  for P:=Low(P) to High(P) do begin
    B:=TMenuButton.Create(Self);B.Name:='GraphicsPreset_'+IntToStr(Ord(P));
    B.Tag:=Ord(P);B.AutoIcon:=False;B.FontSize:=17;B.MinHeight:=44;
    BindUiText(B,GraphicsPresetTitles[P]);B.OnClick:=@ClickPreset;
    FPresetButtons[P]:=B;FPresetFlow.InsertFront(B);
  end;
  FPresetHint:=TMenuLabel.Create(Self);FPresetHint.FontSize:=14;FPresetHint.Color:=MenuMuted;
  InsertFront(FPresetHint);
  FAutoButton := TMenuButton.Create(Self);
  FAutoButton.Name := 'GraphicsAuto'; FAutoButton.AutoIcon := False;
  BindUiText(FAutoButton, 'Auto'); FAutoButton.FontSize := 18;
  FAutoButton.OnClick := @ClickAuto; InsertFront(FAutoButton);
  FAutoHint := TMenuLabel.Create(Self); FAutoHint.FontSize := 15;
  FAutoHint.Color := MenuMuted;
  BindUiText(FAutoHint, 'Test rendering and available GPU memory to choose settings.');
  InsertFront(FAutoHint);
  FAutoResult := TMenuLabel.Create(Self); FAutoResult.FontSize := 15;
  FAutoResult.Name := 'GraphicsAutoResult'; FAutoResult.Color := MenuMuted;
  FAutoResult.Caption := '';
  InsertFront(FAutoResult);
  for O := Low(TGraphicsOption) to High(TGraphicsOption) do
  begin
    FRows[O] := TCastleUserInterface.Create(Self);
    InsertFront(FRows[O]);
    FLabels[O] := TMenuLabel.Create(Self);
    BindUiText(FLabels[O], GraphicsTitles[O]);
    FLabels[O].FontSize := 18;
    FLabels[O].Anchor(hpLeft); FLabels[O].Anchor(vpTop, -8);
    FRows[O].InsertFront(FLabels[O]);
    FChoices[O] := TMenuFlow.Create(Self);
    FChoices[O].WidthFraction := 0;
    FChoices[O].Spacing := 7;
    FRows[O].InsertFront(FChoices[O]);
    SetLength(FButtons[O], GraphicsChoiceCount(O));
    for I := 0 to High(FButtons[O]) do
    begin
      B := TMenuButton.Create(Self);
      B.Name := 'Graphics_' + GraphicsKeys[O] + '_' + IntToStr(I);
      B.AutoIcon := False;
      B.FontSize := 16;
      B.PaddingHorizontal := 12; B.PaddingVertical := 8;
      B.MinWidth := 45;
      BindUiText(B, GraphicsChoiceCaption(O, I));
      B.Tag := Ord(O)*16 + I;
      B.OnClick := @ClickChoice;
      FButtons[O][I] := B;
      FChoices[O].InsertFront(B);
    end;
    FHints[O] := TMenuLabel.Create(Self);
    FHints[O].FontSize := 14; FHints[O].Color := MenuMuted;
    if O<>goTrees then BindUiText(FHints[O], GraphicsHints[O]);
    FRows[O].InsertFront(FHints[O]);
  end;
  ObserveUiLanguage(Self,@LanguageChanged);
  Refresh;
end;

destructor TGraphicsPanel.Destroy;
begin
  FreeAndNil(FAutoRun);
  inherited;
end;

procedure TGraphicsPanel.ClickPreset(Sender:TObject);
begin
  if (FAutoRun<>nil) and not FAutoRun.Completed then Exit;
  Settings.ApplyGraphicsPreset(TGraphicsPreset(TComponent(Sender).Tag));
  Refresh;
end;

procedure TGraphicsPanel.ClickAuto(Sender: TObject);
begin
  if (FAutoRun <> nil) and not FAutoRun.Completed then Exit;
  { Release its GPU resources before Auto queries memory. Hidden preview
    textures must not bias memory selection or consume a second render. }
  if FPreview<>nil then begin FPreview.Suspended:=True;FPreview.ReleaseScene end;
  FreeAndNil(FAutoRun);
  FAutoResult.Caption := '';
  FAutoRun := TGraphicsAutoRun.Create(Self);
  try FAutoRun.BeginRun(Container);
  except
    FreeAndNil(FAutoRun);
    if FPreview<>nil then FPreview.Suspended:=False;
    FAutoResult.Caption := UiText('Automatic setup failed. Previous settings restored.');
  end;
end;

procedure TGraphicsPanel.LanguageChanged(Sender:TObject);
begin Refresh end;

procedure TGraphicsPanel.Refresh;
var O: TGraphicsOption; I,V: Integer; Shadows: Boolean; Detail:TVegetationDetail;Values:TGraphicsValues;P:TGraphicsPreset;Selected:Integer;PresetValues:TGraphicsValues;
begin
  Shadows := Settings.GetGraphicsOption(Ord(goShadowSize)) <> 0;
  for O := Low(TGraphicsOption) to High(TGraphicsOption) do
  begin
    V := Settings.GetGraphicsOption(Ord(O));
    for I := 0 to High(FButtons[O]) do
    begin
      SelectMenuButton(FButtons[O][I], V = GraphicsChoiceValue(O,I));
      FButtons[O][I].Enabled := Shadows or not (O in [goShadowFilter, goShadowDistance,goWorldShadows,goRtxReflections]);
      if O=goRtxReflections then FButtons[O][I].Enabled:=Shadows and
        (Settings.GetGraphicsOption(Ord(goWorldShadows))=2);
      FButtons[O][I].Enabled := FButtons[O][I].Enabled and
        (EffectiveGraphicsValue(O, GraphicsChoiceValue(O,I)) = GraphicsChoiceValue(O,I));
    end;
  end;
  for O:=Low(O) to High(O) do Values[O]:=Settings.GetGraphicsOption(Ord(O));
  Selected:=MatchingGraphicsPreset(Values);
  for P:=Low(P) to High(P) do begin
    SelectMenuButton(FPresetButtons[P],Ord(P)=Selected);
    PresetValues:=GraphicsPresetValues(P,Values);
    FPresetButtons[P].Enabled:=MatchingGraphicsPreset(PresetValues)=Ord(P);
  end;
  if Selected<0 then FPresetHint.Caption:=UiText('Custom settings')
  else FPresetHint.Caption:=UiText(GraphicsPresetHints[TGraphicsPreset(Selected)]);
  Detail:=VegetationPreset(Settings.GetGraphicsOption(Ord(goTrees)));
  FHints[goTrees].Caption:=UiText(GraphicsHints[goTrees]);
  if Settings.GetGraphicsOption(Ord(goTrees))<>0 then
    FHints[goTrees].Caption:=FHints[goTrees].Caption+#10+
      Format(UiText('Trees: up to %d m; grass blades: up to %d m; tree cache: up to %d MiB.'),
        [Round(Detail.TreeDistance),Round(Detail.Grass.BladeEnd),Detail.TreeCacheMiB]);
  FRevision := Settings.GraphicsRevision;
end;

procedure TGraphicsPanel.ClickChoice(Sender: TObject);
var O: TGraphicsOption; Index: Integer;
begin
  Index := (Sender as TMenuButton).Tag;
  O := TGraphicsOption(Index div 16);
  Settings.SetGraphicsOption(Ord(O), GraphicsChoiceValue(O, Index mod 16));
  Refresh;
end;

procedure TGraphicsPanel.Arrange;
var O: TGraphicsOption; Y, X, Top, H, W: Single;
begin
  W := Max(200, EffectiveWidth);
  FIntro.MaxWidth := W;
  Y := 36 + FIntro.EffectiveHeight + 22;
  FPresetFlow.Width:=W;FPresetFlow.Anchor(hpLeft);FPresetFlow.Anchor(vpTop,-Y);FPresetFlow.Arrange;
  Y:=Y+FPresetFlow.Height+10;FPresetHint.MaxWidth:=W;
  FPresetHint.Anchor(hpLeft);FPresetHint.Anchor(vpTop,-Y);
  Y:=Y+FPresetHint.EffectiveHeight+18;
  FAutoButton.Anchor(hpLeft); FAutoButton.Anchor(vpTop, -Y);
  FAutoHint.MaxWidth := Max(100, W - FAutoButton.EffectiveWidth - 18);
  FAutoHint.Anchor(hpLeft, FAutoButton.EffectiveWidth + 18);
  FAutoHint.Anchor(vpTop, -Y - 5);
  Y := Y + Max(FAutoButton.EffectiveHeight, FAutoHint.EffectiveHeight + 10) + 10;
  FAutoResult.MaxWidth := W;
  FAutoResult.Anchor(hpLeft); FAutoResult.Anchor(vpTop, -Y);
  if FAutoResult.Caption <> '' then Y := Y + FAutoResult.EffectiveHeight + 14;
  for O in GraphicsDisplayOrder do
  begin
    FRows[O].Width := W;
    FRows[O].Anchor(hpLeft); FRows[O].Anchor(vpTop, -Y);
    if W >= 680 then begin X := 240; Top := 0 end
    else begin X := 0; Top := 34 end;
    FLabels[O].MaxWidth := IfThen(X > 0, X-12, W);
    if X=0 then Top:=Max(Top,8+FLabels[O].EffectiveHeight+8);
    FChoices[O].Width := W-X;
    FChoices[O].Anchor(hpLeft, X); FChoices[O].Anchor(vpTop, -Top);
    FChoices[O].Arrange;
    H := Max(8+FLabels[O].EffectiveHeight,Top+Max(36,FChoices[O].EffectiveHeight))+8;
    FHints[O].MaxWidth := W;
    FHints[O].Anchor(hpLeft); FHints[O].Anchor(vpTop, -H);
    FRows[O].Height := H + FHints[O].EffectiveHeight + 22;
    Y := Y + FRows[O].Height;
  end;
  Height := Y;
end;

procedure TGraphicsPanel.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited;
  if (FAutoRun <> nil) and FAutoRun.Completed then
  begin
    FAutoResult.Caption := FAutoRun.ResultText;
    FreeAndNil(FAutoRun);
    if FPreview<>nil then FPreview.Suspended:=False;
    Refresh;
  end;
  if FRevision <> Settings.GraphicsRevision then Refresh;
  Arrange;
end;

end.
