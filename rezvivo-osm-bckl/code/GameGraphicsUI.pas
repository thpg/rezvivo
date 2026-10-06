unit GameGraphicsUI;

{$mode objfpc}{$H+}

interface

uses Classes, CastleUIControls, CastleControls, GameMenuTheme, GameGraphicsOptions,
  GameGraphicsAuto;

type
  TGraphicsPanel = class(TCastleUserInterface)
  private
    FTitle, FIntro: TCastleLabel;
    FAutoButton: TMenuButton;
    FAutoHint, FAutoResult: TCastleLabel;
    FAutoRun: TGraphicsAutoRun;
    FRows: array[TGraphicsOption] of TCastleUserInterface;
    FLabels, FHints: array[TGraphicsOption] of TCastleLabel;
    FChoices: array[TGraphicsOption] of TMenuFlow;
    FButtons: array[TGraphicsOption] of array of TMenuButton;
    FRevision: Cardinal;
    procedure ClickChoice(Sender: TObject);
    procedure ClickAuto(Sender: TObject);
    procedure LanguageChanged(Sender:TObject);
    procedure Arrange;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Refresh;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
  end;

implementation

uses Math, SysUtils, AppSettings, UiTranslations, CastleColors, Osm3dVegetationQuality;

constructor TGraphicsPanel.Create(AOwner: TComponent);
var O: TGraphicsOption; I: Integer; B: TMenuButton;
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

procedure TGraphicsPanel.ClickAuto(Sender: TObject);
begin
  if (FAutoRun <> nil) and not FAutoRun.Completed then Exit;
  FreeAndNil(FAutoRun);
  FAutoResult.Caption := '';
  FAutoRun := TGraphicsAutoRun.Create(Self);
  try FAutoRun.BeginRun(Container);
  except
    FreeAndNil(FAutoRun);
    FAutoResult.Caption := UiText('Automatic setup failed. Previous settings restored.');
  end;
end;

procedure TGraphicsPanel.LanguageChanged(Sender:TObject);
begin Refresh end;

procedure TGraphicsPanel.Refresh;
var O: TGraphicsOption; I,V: Integer; Shadows: Boolean; Detail:TVegetationDetail;
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
    end;
  end;
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
    Refresh;
  end;
  if FRevision <> Settings.GraphicsRevision then Refresh;
  Arrange;
end;

end.
