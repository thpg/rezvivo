unit GameGraphicsAuto;
{$ifdef ANDROID}{$define OpenGLES}{$endif}

{$mode objfpc}{$H+}

interface

uses Classes, CastleUIControls, CastleControls, CastleKeysMouse, CastleTimeUtils,
  CastleGLUtils, GameMenuTheme, GameGraphicsOptions, GameGraphicsBenchmarkScene;

type
  TGraphicsAutoPhase = (gapPreparing, gapWarmup, gapSampling, gapFinished);
  TGraphicsAutoRun = class(TCastleUserInterface)
  private
    FScene: TGraphicsBenchmarkScene;
    FCard: TCastleRectangleControl;
    FTitle, FStatus, FMemoryLabel, FTargetLabel: TCastleLabel;
    FCancel: TMenuButton;
    FMemory: TGLMemoryInfo;
    FHidden: array of TCastleUserInterface;
    FOriginal: TGraphicsValues;
    FPhase: TGraphicsAutoPhase;
    FStarted, FPreview, FCancelled, FMemoryKnown, FMemoryAttempted, FCompleted: Boolean;
    FStartedAt, FPhaseAt, FPhaseFrames, FMemoryAt: QWord;
    FLastFrame: TTimerResult;
    FHaveFrame: Boolean;
    FWallSamples, FGpuSamples: array of Double;
    FTargetFPS, FTier, FMaxTier, FBestTier, FAngle: Integer;
    FTotalMiB, FFreeMiB: Int64;
    FScore, FBestScore: Double;
    FPreviousFps, FResultText: String;
    FOriginalWidth, FOriginalHeight: Integer;
    FFocusedAtStart: Boolean;
    procedure CancelClick(Sender: TObject);
    procedure SetProfile;
    procedure BeginAngle;
    procedure CompleteAngle;
    procedure Finish(Commit: Boolean; const Failure: String = '');
    procedure Restore;
    procedure RefreshText;
    procedure ReadMemory;
    procedure EndFrame;
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure BeginRun(AContainer: TCastleContainer);
    procedure BeforeRender; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
    property Completed: Boolean read FCompleted;
    property ResultText: String read FResultText;
  end;

implementation

uses Math, SysUtils, CastleVectors, CastleColors, {$ifdef OpenGLES}CastleGLES{$else}CastleGL{$endif}, AppSettings,
  GameGraphicsAutoPolicy, GameViewPlay, UiTranslations, DebugLog;

type
  { Last child, after the viewport and the small status card. }
  TAutoFrameEnd = class(TCastleUserInterface)
    Run: TGraphicsAutoRun;
    procedure Render; override;
  end;

procedure TAutoFrameEnd.Render;
begin
  inherited;
  Run.EndFrame;
end;

constructor TGraphicsAutoRun.Create(AOwner: TComponent);
var Tick: TAutoFrameEnd;
begin
  inherited;
  Name := 'GraphicsAutoTest'; FullSize := True;
  FBestTier := -1; FBestScore := Infinity;
  FFreeMiB := -1; FTotalMiB := -1;
  FCard := TCastleRectangleControl.Create(Self);
  FCard.Color := Vector4(0.035, 0.05, 0.07, 0.94);
  FCard.Anchor(hpMiddle); FCard.Anchor(vpTop, -18);
  InsertFront(FCard);
  FTitle := TMenuLabel.Create(Self); FTitle.FontSize := 24;
  BindUiText(FTitle, 'Automatic graphics setup');
  FTitle.Anchor(hpLeft, 20); FTitle.Anchor(vpTop, -16); FCard.InsertFront(FTitle);
  FStatus := TMenuLabel.Create(Self); FStatus.Name := 'GraphicsAutoStatus';
  FStatus.FontSize := 18; FStatus.Anchor(hpLeft, 20); FStatus.Anchor(vpTop, -52);
  FCard.InsertFront(FStatus);
  FTargetLabel := TMenuLabel.Create(Self); FTargetLabel.FontSize := 15;
  FTargetLabel.Anchor(hpLeft, 20); FCard.InsertFront(FTargetLabel);
  FMemoryLabel := TMenuLabel.Create(Self); FMemoryLabel.FontSize := 15;
  FMemoryLabel.Anchor(hpLeft, 20); FCard.InsertFront(FMemoryLabel);
  FCancel := TMenuButton.Create(Self); FCancel.Name := 'GraphicsAutoCancel';
  FCancel.AutoIcon := False; BindUiText(FCancel, 'Cancel'); FCancel.FontSize := 17;
  FCancel.OnClick := @CancelClick; FCancel.Anchor(hpRight, -20);
  FCancel.Anchor(vpBottom, 12); FCard.InsertFront(FCancel);
  Tick := TAutoFrameEnd.Create(Self); Tick.Run := Self; InsertFront(Tick);
end;

destructor TGraphicsAutoRun.Destroy;
begin
  Restore;
  FreeAndNil(FScene);
  FreeAndNil(FMemory);
  inherited;
end;

procedure TGraphicsAutoRun.Notification(AComponent: TComponent; Operation: TOperation);
var I: Integer;
begin
  inherited;
  if Operation = opRemove then
    for I := 0 to High(FHidden) do
      if FHidden[I] = AComponent then FHidden[I] := nil;
end;

procedure TGraphicsAutoRun.BeginRun(AContainer: TCastleContainer);
var O: TGraphicsOption; I, N: Integer; C: TCastleUserInterface;
begin
  if FStarted then Exit;
  for O := Low(O) to High(O) do FOriginal[O] := Settings.GetGraphicsOption(Ord(O));
  FTargetFPS := AutoTargetFPS(FOriginal);
  FPreviousFps := GameFpsModeStr;
  Settings.BeginGraphicsPreview; FPreview := True;
  FStarted := True; FStartedAt := GetTickCount64;
  FPhase := gapPreparing; FPhaseAt := FStartedAt;
  FOriginalWidth := AContainer.PixelsWidth; FOriginalHeight := AContainer.PixelsHeight;
  FFocusedAtStart := AContainer.Focused;
  { Hide, but do not stop or destroy, the existing view stack. A ride and its
    camera remain in place; its Update does not advance during calibration. }
  for I := 0 to AContainer.Controls.Count - 1 do
  begin
    C := AContainer.Controls[I];
    if (C is TCastleView) and C.Exists then
    begin
      N := Length(FHidden); SetLength(FHidden, N + 1); FHidden[N] := C;
      C.FreeNotification(Self); C.Exists := False;
    end;
  end;
  AContainer.Controls.InsertFront(Self);
  SetGameGraphicsBenchmarkActive(True);
  SetGameFpsModeStr('max');
  RefreshText;
end;

procedure TGraphicsAutoRun.ReadMemory;
begin
  FMemoryAt := GetTickCount64;
  FMemoryAttempted := True;
  if FMemory = nil then FMemory := TGLMemoryInfo.Create else FMemory.Refresh;
  FMemoryKnown := (FMemory.TotalAvailableMemory > 0){$ifndef OpenGLES} or GL_ATI_meminfo{$endif};
  if FMemory.TotalAvailableMemory > 0 then
  begin
    FFreeMiB := Max(Int64(0), Int64(FMemory.CurrentAvailableVideoMemory)) div 1024;
    FTotalMiB := Max(Int64(0), Int64(FMemory.DedicatedVideoMemory)) div 1024;
  end else if FMemoryKnown then
  begin
    FFreeMiB := Max(Int64(0), Int64(Min(FMemory.TextureFreeMemory, FMemory.VboFreeMemory))) div 1024;
    FTotalMiB := -1;
  end;
end;

procedure TGraphicsAutoRun.BeforeRender;
begin
  inherited;
  if FStarted and not FCompleted then
    try
      if not FMemoryAttempted then ReadMemory;
    except
      on E: Exception do begin FMemoryKnown := False; FFreeMiB := -1; end;
    end;
end;

procedure TGraphicsAutoRun.SetProfile;
var Values: TGraphicsValues; O: TGraphicsOption;
begin
  Values := GraphicsAutoCandidate(FTier, FOriginal, FMaxTier);
  Values[goVegetationAdaptive] := 0; { Keep each trial reproducible. }
  Values[goFrameLimit] := 0;
  for O := Low(O) to High(O) do
    if Settings.GetGraphicsOption(Ord(O)) <> Values[O] then
      Settings.SetGraphicsOption(Ord(O), Values[O]);
  FScene.ApplyProfile(Values);
  FAngle := 0; FScore := 0;
  BeginAngle;
end;

procedure TGraphicsAutoRun.BeginAngle;
begin
  FScene.SetViewIndex(FAngle);
  FScene.RestartSamples;
  FPhase := gapWarmup; FPhaseAt := GetTickCount64;
  FPhaseFrames := FScene.RenderFrames;
  SetLength(FWallSamples, 0); SetLength(FGpuSamples, 0); FHaveFrame := False;
  RefreshText;
end;

procedure TGraphicsAutoRun.CompleteAngle;
var Ms: Double; MemoryOK: Boolean; Reserve: Int64;
begin
  Ms := GraphicsAutoScore(FWallSamples);
  if Length(FGpuSamples) >= 8 then Ms := Max(Ms, GraphicsAutoScore(FGpuSamples));
  if IsNan(Ms) or IsInfinite(Ms) then
  begin Finish(False, 'Not enough rendered frames for calibration'); Exit end;
  FScore := Max(FScore, Ms);
  if FAngle < GraphicsBenchmarkViewCount-1 then begin Inc(FAngle); BeginAngle; Exit end;
  Logger.Info(Format('[GraphicsAuto] tier=%d frame_ms=%.3f target=%d free_mib=%d samples=%d gpu_samples=%d',
    [FTier, FScore, FTargetFPS, FFreeMiB, Length(FWallSamples), Length(FGpuSamples)]));
  Reserve := Max(Int64(256), Min(Int64(1024), FTotalMiB div 10));
  MemoryOK := not FMemoryKnown or (FFreeMiB >= Reserve);
  if GraphicsAutoPass(FScore, FTargetFPS) and MemoryOK then
  begin FBestTier := FTier; FBestScore := FScore end
  else if FTier = 0 then begin FBestTier := 0; FBestScore := FScore end;
  { Leave room for the next cache/shadow allocation as well as streaming.
    Do not mistake the benchmark's already allocated memory for free space. }
  if (FTier < FMaxTier) and GraphicsAutoPass(FScore, FTargetFPS) and
     (not FMemoryKnown or (FFreeMiB >= Reserve + 192)) then
  begin Inc(FTier); SetProfile end
  else Finish(True);
end;

procedure TGraphicsAutoRun.EndFrame;
var NowTime: TTimerResult; Ms: Double; N: Integer;
begin
  if not FStarted or FCompleted then Exit;
  NowTime := Timer;
  if (FPhase = gapSampling) and FHaveFrame then
  begin
    Ms := TimerSeconds(NowTime, FLastFrame) * 1000;
    N := Length(FWallSamples);
    if (Ms > 0) and (N < 512) then
    begin SetLength(FWallSamples, N + 1); FWallSamples[N] := Ms end;
    while FScene.ReadGpuSample(Ms) do
    begin
      N := Length(FGpuSamples);
      if (Ms > 0) and (N < 512) then
      begin SetLength(FGpuSamples, N + 1); FGpuSamples[N] := Ms end;
    end;
  end;
  FLastFrame := NowTime; FHaveFrame := True;
  if (FPhase in [gapWarmup, gapSampling]) and (GetTickCount64 - FMemoryAt > 1000) then
  begin
    try ReadMemory;
    except on E: Exception do begin FMemoryKnown := False; FFreeMiB := -1 end end;
    { The driver's memory query itself is not a rendering workload. }
    FHaveFrame := False;
  end;
end;

procedure TGraphicsAutoRun.Restore;
var I: Integer;
begin
  try
    if FPreview then Settings.EndGraphicsPreview(False);
  except
    on E: Exception do Logger.Warning('[GraphicsAuto] Restore settings: ' + E.Message);
  end;
  FPreview := Settings.GraphicsPreviewActive;
  if not FStarted then Exit;
  FStarted := False;
  for I := 0 to High(FHidden) do
    if FHidden[I] <> nil then
    begin FHidden[I].Exists := True; FHidden[I].RemoveFreeNotification(Self) end;
  SetLength(FHidden, 0);
  SetGameGraphicsBenchmarkActive(False);
  if (FPreviousFps = 'max') or (FPreviousFps = 'low') or (FPreviousFps = 'vsync') then
    SetGameFpsModeStr(FPreviousFps)
  else SetGameFpsModeStr('settings');
end;

procedure TGraphicsAutoRun.Finish(Commit: Boolean; const Failure: String);
var Values: TGraphicsValues; O: TGraphicsOption;
begin
  if FCompleted then Exit;
  if Commit and (FBestTier >= 0) then
  begin
    Values := GraphicsAutoCandidate(FBestTier, FOriginal, FMaxTier);
    for O := Low(O) to High(O) do Settings.SetGraphicsOption(Ord(O), Values[O]);
    Settings.EndGraphicsPreview(True); FPreview := False;
    FResultText := Format(UiText('Auto: %s. Test: %.0f FPS; target: %d FPS.'),
      [UiText(GraphicsChoiceCaption(goTrees, FBestTier)), 1000 / Max(0.01, FBestScore), FTargetFPS]);
    if not GraphicsAutoPass(FBestScore, FTargetFPS) then
      FResultText := FResultText + #10 + UiText('Minimum settings selected. The target frame rate was not reached.');
    if FMemoryKnown then FResultText := FResultText + #10 +
      Format(UiText('Free GPU memory: %s'), [IntToStr(FFreeMiB) + ' MiB']);
  end else if Failure <> '' then
  begin
    FResultText := UiText('Automatic setup failed. Previous settings restored.');
    Logger.Warning('[GraphicsAuto] ' + Failure);
  end else FResultText := UiText('Automatic setup cancelled. Previous settings restored.');
  FCompleted := True; FPhase := gapFinished;
  Restore;
  Exists := False;
end;

procedure TGraphicsAutoRun.RefreshText;
var Y: Single;
begin
  FCard.Width := Max(260, Min(740, EffectiveWidth - 32));
  FTitle.MaxWidth := FCard.Width - 40;
  FStatus.MaxWidth := FCard.Width - 40;
  FTargetLabel.MaxWidth := FCard.Width - 40;
  FMemoryLabel.MaxWidth := FCard.Width - 40;
  if FPhase = gapPreparing then FStatus.Caption := UiText('Preparing test scene...')
  else FStatus.Caption := Format(UiText('Testing %s (%d/%d)'),
    [UiText(GraphicsChoiceCaption(goTrees, FTier)), FTier * GraphicsBenchmarkViewCount + FAngle + 1,
      (FMaxTier + 1) * GraphicsBenchmarkViewCount]);
  FStatus.Anchor(vpTop, -(24 + FTitle.EffectiveHeight));
  Y := 32 + FTitle.EffectiveHeight + FStatus.EffectiveHeight;
  FTargetLabel.Caption := Format(UiText('Target: %d FPS'), [FTargetFPS]);
  FTargetLabel.Anchor(vpTop, -Y); Y := Y + FTargetLabel.EffectiveHeight + 8;
  if FMemoryKnown then FMemoryLabel.Caption := Format(UiText('Free GPU memory: %s'), [IntToStr(FFreeMiB) + ' MiB'])
  else FMemoryLabel.Caption := UiText('GPU memory unavailable; using conservative limits.');
  FMemoryLabel.Anchor(vpTop, -Y);
  FCard.Height := Y + FMemoryLabel.EffectiveHeight + FCancel.EffectiveHeight + 28;
end;

procedure TGraphicsAutoRun.CancelClick(Sender: TObject);
begin FCancelled := True end;

function TGraphicsAutoRun.Press(const Event: TInputPressRelease): Boolean;
begin
  if Event.IsKey(keyEscape) then FCancelled := True;
  Result := True;
end;

procedure TGraphicsAutoRun.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var Elapsed: QWord;
begin
  inherited;
  HandleInput := False;
  if not FStarted or FCompleted then Exit;
  try
    if FCancelled then begin Finish(False); Exit end;
    if FFocusedAtStart and not Container.Focused then begin Finish(False); Exit end;
    if (Container.PixelsWidth <> FOriginalWidth) or (Container.PixelsHeight <> FOriginalHeight) then
    begin Finish(False, 'Window size changed during calibration'); Exit end;
    if GetTickCount64 - FStartedAt > 240000 then
    begin Finish(False, 'Calibration timed out'); Exit end;
    if (FScene <> nil) and (FScene.ErrorText <> '') then
    begin Finish(False, FScene.ErrorText); Exit end;
    Elapsed := GetTickCount64 - FPhaseAt;
    case FPhase of
      gapPreparing:
        if FMemoryAttempted then
        begin
          FMaxTier := GraphicsAutoMemoryTier(FFreeMiB, FTotalMiB, FMemoryKnown);
          FScene := TGraphicsBenchmarkScene.Create(Self); FScene.FullSize := True;
          InsertBack(FScene); FTier := 0; SetProfile;
        end;
      gapWarmup:
        if FScene.Ready and (Elapsed >= 2000) and (FScene.RenderFrames - FPhaseFrames >= 30) then
        begin
          FScene.RestartSamples; FHaveFrame := False;
          FPhase := gapSampling; FPhaseAt := GetTickCount64;
        end
        else if Elapsed > 90000 then Finish(False, 'Test scene did not finish preparing');
      gapSampling:
        if ((Elapsed >= 1200) and (Length(FWallSamples) >= 60)) or (Elapsed >= 6000) then
          CompleteAngle;
    end;
    RefreshText;
  except
    on E: Exception do Finish(False, E.ClassName + ': ' + E.Message);
  end;
end;

end.
