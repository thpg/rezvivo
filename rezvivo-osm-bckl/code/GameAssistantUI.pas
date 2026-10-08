unit GameAssistantUI;
{$mode objfpc}{$H+}{$codepage UTF8}

interface

uses Classes, fpjson, CastleUIControls, CastleControls, CastleKeysMouse,
  GameMenuTheme, GameUiNavigation;

type
  { A non-modal conversation panel, outside the view stack. The current menu
    or ride remains the active view while the user works with the assistant. }
  TViewAssistant = class(TCastleUserInterface)
  private
    FPanel: TMenuPanel;
    FTitle, FConnection, FInterval, FError, FHint: TCastleLabel;
    FVoiceInputStatus, FVoiceOutputStatus: TCastleLabel;
    FConnectionHelp: TCastleLabel;
    FVoiceMeter, FVoiceLevel: TCastleRectangleControl;
    FScroll: TMenuScrollView;
    FMessages: TComponent;
    FInput: TMenuEdit;
    FSend, FClose, FDisconnect, FLatest: TMenuButton;
    FMicrophone, FReadReplies, FStopSpeech: TMenuButton;
    FAllowConnection, FCopyConnection: TMenuButton;
    FKeyboard: TUiKeyboardNavigation;
    FSnapshot: TJSONObject;
    FLocalStatus: TJSONObject;
    FRevision, FVoiceRevision, FContextRevision: QWord;
    FLiveElapsed, FVoiceElapsed, FLocalElapsed, FContentWidth: Single;
    FLastLanguage, FDraft, FVoiceState, FVoiceNotice: String;
    FConnectionNotice: String;
    FClosing, FNeedFocus, FVoiceCancelledForFocus: Boolean;
    FKeyboardActive: Boolean;
    FPanelButtons: TCastleMouseButtons;
    procedure BuildControls;
    function OwnsKeyboard: Boolean;
    procedure ReleaseKeyboard;
    procedure ClickSend(Sender: TObject);
    procedure ClickClose(Sender: TObject);
    procedure ClickDisconnect(Sender: TObject);
    procedure ClickLatest(Sender: TObject);
    procedure ClickMicrophone(Sender: TObject);
    procedure ClickReadReplies(Sender: TObject);
    procedure ClickStopSpeech(Sender: TObject);
    procedure ClickAllowConnection(Sender: TObject);
    procedure ClickCopyConnection(Sender: TObject);
    procedure RefreshLocalConnection;
    procedure InputChanged(Sender: TObject);
    procedure RefreshConversation;
    procedure SyncDraftContext;
    procedure RefreshLiveStatus;
    procedure RefreshVoice;
    procedure BuildMessages(const ToBottom: Boolean);
    procedure Layout;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Open(const AContainer: TCastleContainer);
    procedure Close;
    procedure Resize; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function PreviewPress(const Event: TInputPressRelease): Boolean; override;
    function Press(const Event: TInputPressRelease): Boolean; override;
    function Release(const Event: TInputPressRelease): Boolean; override;
    function Motion(const Event: TInputMotion): Boolean; override;
    procedure RenderOverChildren; override;
  end;

procedure ShowAssistant(const Container: TCastleContainer);
procedure DismissAssistant(const Container: TCastleContainer);
function AssistantVisible(const Container: TCastleContainer): Boolean;

implementation

uses SysUtils, Math, CastleWindow, CastleVectors, UiTranslations,
  GameAssistant, GameAssistantMcp, GameAssistantVoice, GameMcpServer;

const AssistantSeparator: String = ' · ';
var AssistantView: TViewAssistant;

function AssistantVisible(const Container: TCastleContainer): Boolean;
begin
  Result := (Container <> nil) and (AssistantView <> nil) and
    AssistantView.Exists and (AssistantView.Container = Container);
end;

procedure DismissAssistant(const Container: TCastleContainer);
begin
  if AssistantVisible(Container) then AssistantView.Close;
end;

procedure ShowAssistant(const Container: TCastleContainer);
begin
  if Container = nil then Exit;
  if AssistantView = nil then begin
    AssistantView := TViewAssistant.Create(Application);
    AssistantView.Name := 'AssistantView';
  end;
  if not AssistantVisible(Container) then AssistantView.Open(Container);
end;

constructor TViewAssistant.Create(AOwner: TComponent);
begin
  inherited;
  FullSize := True; KeepInFront := True; Exists := False;
end;

destructor TViewAssistant.Destroy;
begin
  FreeAndNil(FSnapshot); FreeAndNil(FMessages); FreeAndNil(FLocalStatus);
  inherited;
end;

procedure TViewAssistant.Open(const AContainer: TCastleContainer);
begin
  if Container <> AContainer then begin
    if Container <> nil then Container.Controls.Remove(Self);
    AContainer.Controls.InsertFront(Self);
  end;
  AContainer.ForceCaptureInput := nil;
  SyncAssistantContext(True); SyncDraftContext;
  Exists := True; FClosing := False; FNeedFocus := True;
  FKeyboardActive := True; FPanelButtons := []; FLiveElapsed := 0;
  FContentWidth := -1; FRevision := High(QWord); FLastLanguage := UiLanguage;
  FVoiceRevision := High(QWord); FVoiceElapsed := 0;
  FVoiceState := 'idle'; FVoiceNotice := ''; FVoiceCancelledForFocus := False;
  FLocalElapsed := 0; FConnectionNotice := '';
  if FPanel = nil then BuildControls;
  FInput.Text := FDraft;
  RefreshLocalConnection; Layout; RefreshConversation; RefreshLiveStatus; RefreshVoice;
end;

procedure TViewAssistant.BuildControls;
  function Button(const ControlName, Text: String; Handler: TNotifyEvent): TMenuButton;
  begin
    Result := TMenuButton.Create(Self); Result.Name := ControlName;
    Result.AutoSize := False; Result.AutoIcon := False;
    BindUiText(Result, Text); Result.OnClick := Handler; FPanel.InsertFront(Result);
  end;
begin
  FPanel := TMenuPanel.Create(Self); FPanel.Name := 'AssistantPanel';
  FPanel.Color := MenuBackground; InsertFront(FPanel);
  FTitle := TMenuLabel.Create(Self); BindUiText(FTitle, 'Assistant');
  FTitle.CustomFont := MenuFont(True); FPanel.InsertFront(FTitle);
  FConnection := TMenuLabel.Create(Self); FConnection.Name := 'AssistantConnection';
  FPanel.InsertFront(FConnection);
  FInterval := TMenuLabel.Create(Self); FInterval.Name := 'AssistantWorkoutStatus';
  FInterval.Color := MenuMuted; FPanel.InsertFront(FInterval);
  FScroll := TMenuScrollView.Create(Self); FScroll.Name := 'AssistantHistory';
  FPanel.InsertFront(FScroll);
  FClose := Button('AssistantClose', 'Close', @ClickClose); FClose.Style := mbGhost;
  FDisconnect := Button('AssistantDisconnect', 'Disconnect agent', @ClickDisconnect);
  FDisconnect.Style := mbGhost;
  FAllowConnection := Button('AssistantAllowConnection', 'Enable connection', @ClickAllowConnection);
  FCopyConnection := Button('AssistantCopyConnection', 'Copy connection command', @ClickCopyConnection);
  FCopyConnection.Style := mbGhost;
  FConnectionHelp := TMenuLabel.Create(Self); FConnectionHelp.Html := False;
  FConnectionHelp.Name := 'AssistantConnectionHelp'; FConnectionHelp.Color := MenuMuted;
  FPanel.InsertFront(FConnectionHelp);
  FLatest := Button('AssistantLatest', 'Latest messages', @ClickLatest); FLatest.Style := mbGhost;
  FLatest.Exists := False;
  FInput := TMenuEdit.Create(Self); FInput.Name := 'AssistantMessage';
  FInput.MaxLength := 4096; FInput.Text := FDraft;
  BindUiText(FInput, 'Write to the assistant...', 'Placeholder');
  FInput.OnChange := @InputChanged; FPanel.InsertFront(FInput);
  FSend := Button('AssistantSend', 'Send', @ClickSend); FSend.Style := mbPrimary;
  FError := TMenuLabel.Create(Self); FError.Name := 'AssistantMessageStatus';
  FError.Color := MenuMuted; FPanel.InsertFront(FError);
  FHint := TMenuLabel.Create(Self);
  BindUiText(FHint, 'Enter to send · Esc to close'); FHint.Color := MenuMuted;
  FPanel.InsertFront(FHint);
  FMicrophone := Button('AssistantMicrophone', 'Microphone', @ClickMicrophone);
  FReadReplies := Button('AssistantReadReplies', 'Read replies aloud', @ClickReadReplies);
  FReadReplies.Toggle := True;
  FStopSpeech := Button('AssistantStopSpeech', 'Stop voice', @ClickStopSpeech);
  FStopSpeech.Style := mbGhost;
  FVoiceInputStatus := TMenuLabel.Create(Self);
  FVoiceInputStatus.Name := 'AssistantVoiceInputStatus'; FVoiceInputStatus.Html := False;
  FVoiceInputStatus.Color := MenuMuted; FPanel.InsertFront(FVoiceInputStatus);
  FVoiceOutputStatus := TMenuLabel.Create(Self);
  FVoiceOutputStatus.Name := 'AssistantVoiceOutputStatus'; FVoiceOutputStatus.Html := False;
  FVoiceOutputStatus.Color := MenuMuted; FPanel.InsertFront(FVoiceOutputStatus);
  FVoiceMeter := TCastleRectangleControl.Create(Self);
  FVoiceMeter.Name := 'AssistantMicrophoneLevel'; FVoiceMeter.Color := Vector4(0.12, 0.2, 0.24, 1);
  FVoiceMeter.Exists := False; FPanel.InsertFront(FVoiceMeter);
  FVoiceLevel := TCastleRectangleControl.Create(Self);
  FVoiceLevel.Color := MenuAccent; FVoiceLevel.Anchor(hpLeft); FVoiceLevel.Anchor(vpBottom);
  FVoiceMeter.InsertFront(FVoiceLevel);
  FKeyboard := TUiKeyboardNavigation.Create(Self); InsertFront(FKeyboard);
end;

procedure TViewAssistant.Close;
begin
  if FClosing then Exit;
  FClosing := True; Exists := False; FPanelButtons := [];
  CancelAssistantVoiceInput;
  if FInput <> nil then FDraft := FInput.Text;
  ReleaseKeyboard;
  if Container <> nil then Container.ReleaseCapture(Self);
end;

function TViewAssistant.OwnsKeyboard: Boolean;
var C: TCastleUserInterface;
begin
  Result := False;
  if not Exists or FClosing or (Container = nil) then Exit;
  C := Container.ForceCaptureInput;
  if C = nil then Exit(FKeyboardActive);
  while (C <> nil) and (C <> Self) do C := C.Parent;
  Result := C = Self;
end;

procedure TViewAssistant.ReleaseKeyboard;
begin
  FNeedFocus := False; FKeyboardActive := False;
  if FKeyboard <> nil then FKeyboard.Clear;
  if (Container <> nil) and (Container.ForceCaptureInput = FInput) then
    Container.ForceCaptureInput := nil;
  if FInput <> nil then FInput.Focused := False;
end;

procedure TViewAssistant.Layout;
var S, W, H, HeaderExtra: Single;
begin
  if (FPanel = nil) or (EffectiveWidth <= 0) or (EffectiveHeight <= 0) then Exit;
  S := Max(0.65, Min(1, UIScale));
  W := Min(620 / S, Max(240, EffectiveWidth - 24 / S));
  H := Min(880 / S, Max(300, EffectiveHeight - 24 / S));
  FPanel.Width := W; FPanel.Height := H;
  FPanel.Anchor(hpRight, -12 / S); FPanel.Anchor(vpMiddle);
  FTitle.FontSize := 24 / S; FTitle.Anchor(hpLeft, 20 / S); FTitle.Anchor(vpTop, -18 / S);
  FClose.Width := 100 / S; FClose.Height := 36 / S; FClose.FontSize := 14 / S;
  FClose.Anchor(hpRight, -12 / S); FClose.Anchor(vpTop, -12 / S);
  FConnection.FontSize := 15 / S; FConnection.MaxWidth := Max(90, W - 40 / S);
  FConnection.Anchor(hpLeft, 20 / S); FConnection.Anchor(vpTop, -60 / S);
  FDisconnect.Width := 156 / S; FDisconnect.Height := 28 / S; FDisconnect.FontSize := 12 / S;
  FDisconnect.Anchor(hpRight, -16 / S); FDisconnect.Anchor(vpTop, -87 / S);
  FAllowConnection.Width := Min(212 / S, (W - 44 / S) * 0.5);
  FAllowConnection.Height := 28 / S; FAllowConnection.FontSize := 12 / S;
  FAllowConnection.Anchor(hpLeft, 20 / S); FAllowConnection.Anchor(vpTop, -87 / S);
  FCopyConnection.Width := Min(236 / S, W - FAllowConnection.Width - 52 / S);
  FCopyConnection.Height := 28 / S; FCopyConnection.FontSize := 12 / S;
  FCopyConnection.Anchor(hpRight, -16 / S); FCopyConnection.Anchor(vpTop, -87 / S);
  FConnectionHelp.FontSize := 11 / S; FConnectionHelp.MaxWidth := W - 40 / S;
  FConnectionHelp.Anchor(hpLeft, 20 / S); FConnectionHelp.Anchor(vpTop, -121 / S);
  HeaderExtra := 0;
  if FConnectionHelp.Exists then HeaderExtra := 42 / S;
  FInterval.FontSize := 14 / S; FInterval.MaxWidth := W - 40 / S;
  FInterval.Anchor(hpLeft, 20 / S); FInterval.Anchor(vpTop, -124 / S - HeaderExtra);
  FScroll.Width := W - 32 / S; FScroll.Height := Max(48 / S, H - 408 / S - HeaderExtra);
  FScroll.Anchor(hpLeft, 16 / S); FScroll.Anchor(vpTop, -178 / S - HeaderExtra);
  FInput.FontSize := 16 / S; FInput.Width := Max(100, W - 162 / S);
  FInput.Height := 44 / S; FInput.AutoSizeHeight := False;
  FInput.Anchor(hpLeft, 20 / S); FInput.Anchor(vpBottom, 146 / S);
  FSend.Width := 110 / S; FSend.Height := 44 / S; FSend.FontSize := 15 / S;
  FSend.Anchor(hpRight, -20 / S); FSend.Anchor(vpBottom, 146 / S);
  FError.FontSize := 11 / S; FError.MaxWidth := W - 40 / S;
  FError.Anchor(hpLeft, 20 / S); FError.Anchor(vpBottom, 120 / S);
  FHint.FontSize := 11 / S; FHint.MaxWidth := Max(150 / S, W - 238 / S);
  FHint.Anchor(hpLeft, 20 / S); FHint.Anchor(vpBottom, 202 / S);
  FLatest.Width := 180 / S; FLatest.Height := 28 / S; FLatest.FontSize := 12 / S;
  FLatest.Anchor(hpRight, -20 / S); FLatest.Anchor(vpBottom, 194 / S);
  FMicrophone.Width := Min(164 / S, (W - 48 / S) * 0.44);
  FMicrophone.Height := 34 / S; FMicrophone.FontSize := 13 / S;
  FMicrophone.Anchor(hpLeft, 20 / S); FMicrophone.Anchor(vpBottom, 82 / S);
  FVoiceInputStatus.FontSize := 12 / S;
  FVoiceInputStatus.MaxWidth := W - FMicrophone.Width - 52 / S;
  FVoiceInputStatus.Anchor(hpLeft, FMicrophone.Width + 32 / S);
  FVoiceInputStatus.Anchor(vpBottom, 84 / S);
  FReadReplies.Width := Min(236 / S, W - 188 / S);
  FReadReplies.Height := 32 / S; FReadReplies.FontSize := 13 / S;
  FReadReplies.Anchor(hpLeft, 20 / S); FReadReplies.Anchor(vpBottom, 42 / S);
  FStopSpeech.Width := 136 / S; FStopSpeech.Height := 32 / S; FStopSpeech.FontSize := 13 / S;
  FStopSpeech.Anchor(hpRight, -20 / S); FStopSpeech.Anchor(vpBottom, 42 / S);
  FVoiceOutputStatus.FontSize := 11 / S; FVoiceOutputStatus.MaxWidth := W - 40 / S;
  FVoiceOutputStatus.Anchor(hpLeft, 20 / S); FVoiceOutputStatus.Anchor(vpBottom, 14 / S);
  FVoiceMeter.Width := FMicrophone.Width; FVoiceMeter.Height := 3 / S;
  FVoiceMeter.Anchor(hpLeft, 20 / S); FVoiceMeter.Anchor(vpBottom, 77 / S);
  FVoiceLevel.Height := FVoiceMeter.Height;
  FVoiceRevision := High(QWord);
  if (FSnapshot <> nil) and (Abs(FContentWidth - FScroll.Width) > 0.5) then
    BuildMessages(False);
end;

procedure TViewAssistant.Resize;
begin inherited; Layout; end;

procedure TViewAssistant.BuildMessages(const ToBottom: Boolean);
var Messages: TJSONArray; Item: TJSONObject; Card: TMenuPanel;
  RoleLabel, Body: TCastleLabel; I: Integer; S, Y, W, OldScroll: Single;
  Speaker, Text, Role: String; AtBottom: Boolean;
  procedure AddMessage(const Who, Content: String; IsUser: Boolean);
  begin
    Card := TMenuPanel.Create(FMessages); Card.Width := W;
    Card.Anchor(hpLeft); Card.Anchor(vpTop, -Y);
    if IsUser then Card.Color := Vector4(0.08, 0.19, 0.22, 1) else Card.Color := MenuSurface;
    FScroll.ScrollArea.InsertFront(Card);
    RoleLabel := TMenuLabel.Create(FMessages);
    RoleLabel.Html := False;
    RoleLabel.FontSize := 12 / S; RoleLabel.Color := MenuAccent;
    RoleLabel.MaxWidth := W - 28 / S;
    RoleLabel.Caption := MenuEllipsis(Who, RoleLabel.Font, RoleLabel.MaxWidth * UIScale);
    RoleLabel.Anchor(hpLeft, 14 / S); RoleLabel.Anchor(vpTop, -10 / S); Card.InsertFront(RoleLabel);
    Body := TMenuLabel.Create(FMessages); Body.Caption := Content;
    Body.Html := False;
    Body.FontSize := 16 / S; Body.MaxWidth := W - 28 / S;
    Body.Anchor(hpLeft, 14 / S); Body.Anchor(vpTop, -32 / S); Card.InsertFront(Body);
    Card.Height := Max(64 / S, Body.EffectiveHeight + 46 / S);
    Y := Y + Card.Height + 10 / S;
  end;
begin
  if (FSnapshot = nil) or (FScroll = nil) then Exit;
  S := Max(0.65, Min(1, UIScale));
  AtBottom := FScroll.ScrollMax - FScroll.Scroll < 24 / S;
  OldScroll := FScroll.Scroll;
  FreeAndNil(FMessages); FMessages := TComponent.Create(Self);
  W := Max(100, FScroll.Width - 18 / S); Y := 0;
  Messages := FSnapshot.Arrays['messages'];
  if Messages.Count = 0 then AddMessage(UiText('Your assistant'),
    UiText('Connect an MCP agent to REZVIVO. Its name will appear here. Ask it about the ride, plan a workout or follow your intervals together.'), False);
  for I := 0 to Messages.Count - 1 do begin
    Item := TJSONObject(Messages[I]); Role := Item.Get('role', 'assistant');
    Text := Item.Get('text', '');
    if Role = 'user' then Speaker := UiText('You')
    else if Role = 'system' then Speaker := 'REZVIVO'
    else Speaker := Item.Get('sender_name', FSnapshot.Get('agent_name', UiText('Assistant')));
    AddMessage(Speaker, Text, Role = 'user');
  end;
  FScroll.ScrollArea.Height := Max(FScroll.Height, Y);
  FScroll.ScrollArea.Width := W; FContentWidth := FScroll.Width;
  if ToBottom or AtBottom then FScroll.Scroll := FScroll.ScrollMax
  else FScroll.Scroll := OldScroll;
end;

procedure TViewAssistant.RefreshConversation;
var AgentName, Status: String;
begin
  SyncAssistantContext;SyncDraftContext;
  FreeAndNil(FSnapshot); FSnapshot := Assistant.Snapshot;
  FRevision := Assistant.Revision; FLastLanguage := UiLanguage;
  AgentName := FSnapshot.Get('agent_name', '');
  if FSnapshot.Get('connected', False) then begin
    FConnectionNotice := '';
    Status := UiText('Connected') + AssistantSeparator + AgentName; FConnection.Color := MenuAccent;
  end else begin
    if FSnapshot.Get('transport_available', False) then Status := UiText('Waiting for an agent')
    else if (FLocalStatus <> nil) and FLocalStatus.Get('supported', False) then
      Status := UiText('No agent connected')
    else Status := UiText('Agent connection is unavailable');
    FConnection.Color := MenuMuted;
  end;
  FConnection.Caption := MenuEllipsis(Status, FConnection.Font, FConnection.MaxWidth * UIScale);
  FDisconnect.Exists := FSnapshot.Get('connected', False);
  if not Assistant.Connected then AssistantVoice.CancelInput;
  FVoiceRevision := High(QWord);
  BuildMessages(False); InputChanged(nil);
  RefreshLocalConnection;
end;

procedure TViewAssistant.SyncDraftContext;
begin
  if FContextRevision=Assistant.ContextRevision then Exit;
  FContextRevision:=Assistant.ContextRevision;FDraft:='';FVoiceNotice:='';
  if FInput<>nil then FInput.Text:='';
end;

procedure TViewAssistant.RefreshLocalConnection;
var Data: TJSONObject; Supported, Enabled, WasVisible: Boolean; HelpText: String;
begin
  if FAllowConnection = nil then Exit;
  Data := LocalMcpStatus;
  FreeAndNil(FLocalStatus); FLocalStatus := Data;
  Supported := Data.Get('supported', False);
  Enabled := Data.Get('enabled', False);
  WasVisible := FConnectionHelp.Exists;
  FAllowConnection.Exists := Supported and not Assistant.Connected;
  FAllowConnection.Enabled := Supported;
  if Enabled then FAllowConnection.Caption := UiText('Close connection')
  else FAllowConnection.Caption := UiText('Enable connection');
  FCopyConnection.Exists := Supported and Enabled and not Assistant.Connected;
  FCopyConnection.Enabled := FCopyConnection.Exists;
  FConnectionHelp.Exists := Supported;
  if FConnectionNotice <> '' then HelpText := UiText(FConnectionNotice)
  else if Data.Get('error', '') <> '' then HelpText := UiText('Could not open a local connection. Try again.')
  else if Assistant.Connected then HelpText := UiText('Disconnecting the agent leaves your ride running.')
  else if Enabled then HelpText := UiText('Use the copied command in your agent MCP configuration. Keep REZVIVO open.')
  else HelpText := UiText('Connect your agent to this game to manage rides, workouts and the map.');
  if WasVisible <> FConnectionHelp.Exists then Layout;
  FConnectionHelp.Caption := MenuSummary(HelpText, FConnectionHelp.Font,
    Max(100, FConnectionHelp.MaxWidth * UIScale), 2);
end;

procedure TViewAssistant.ClickAllowConnection(Sender: TObject);
var ErrorText: String;
begin
  FConnectionNotice := '';
  if (FLocalStatus <> nil) and FLocalStatus.Get('enabled', False) then
    DisableLocalMcp
  else if not EnableLocalMcp(ErrorText) then
    FConnectionNotice := 'Could not open a local connection. Try again.';
  RefreshLocalConnection; RefreshConversation; RefreshVoice;
end;

procedure TViewAssistant.ClickCopyConnection(Sender: TObject);
begin
  RefreshLocalConnection;
  if not FLocalStatus.Get('enabled', False) then Exit;
  try
    Clipboard.AsText := FLocalStatus.Get('command', '');
    FConnectionNotice := 'Connection command copied. Paste it into your agent MCP configuration.';
  except
    FConnectionNotice := 'Could not copy the command. Try again.';
  end;
  RefreshLocalConnection;
end;

function TimeText(const Seconds: Double): String;
var N: Integer;
begin N := Max(0, Ceil(Seconds)); Result := Format('%d:%.2d', [N div 60, N mod 60]); end;

procedure TViewAssistant.RefreshLiveStatus;
var Data, Workout: TJSONObject; V: TJSONData; Text, State: String; Number, Count: Integer;
begin
  Data := AssistantLiveStatus;
  try
    V := Data.Find('workout');
    if V is TJSONObject then begin
      Workout := TJSONObject(V); State := Workout.Get('state', 'idle');
      if (State = 'running') or (State = 'paused') or (State = 'ready') then begin
        Number := Workout.Get('number', 0); Count := Workout.Get('count', 0);
        Text := UiText('Interval') + ' ' + IntToStr(Number);
        if Count > 0 then Text := Text + '/' + IntToStr(Count);
        if Workout.Get('name', '') <> '' then Text := Text + AssistantSeparator +
          MenuEllipsis(Workout.Get('name', ''), FInterval.Font, Max(40, FInterval.MaxWidth * UIScale - 155));
        Text := Text + #10;
        if Workout.Get('auto_paused', False) then Text := Text + UiText('Auto-paused') + AssistantSeparator
        else if State = 'paused' then Text := Text + UiText('Paused') + AssistantSeparator
        else if State = 'ready' then Text := Text + UiText('Ready') + AssistantSeparator;
        Text := Text + TimeText(Workout.Get('remaining_s', 0.0)) + AssistantSeparator +
          IntToStr(Round(Workout.Get('target_watts', 0.0))) + ' ' + UiText('W');
      end else Text := UiText('No active workout');
    end else Text := UiText('No active workout');
    if Text <> FInterval.Caption then FInterval.Caption := Text;
  finally Data.Free; end;
end;

function VoiceErrorText(const Code: String; const Output: Boolean): String;
begin
  if Code = 'speech_microphone_missing' then
    Result := UiText('No microphone found. Connect one and try again.')
  else if Code = 'speech_microphone_busy' then
    Result := UiText('The microphone is being used by another application.')
  else if Code = 'speech_microphone_denied' then
    Result := UiText('Microphone access is blocked. Check Windows privacy settings.')
  else if Code = 'speech_microphone_format' then
    Result := UiText('This microphone does not support the recording format.')
  else if Code = 'speech_microphone_failed' then
    Result := UiText('Could not start the microphone. Check the device.')
  else if Code = 'speech_microphone_close_failed' then
    Result := UiText('The microphone driver did not stop. Restart REZVIVO before recording again.')
  else if Code = 'speech_model_missing' then
    Result := UiText('The speech recognition model for this language is not installed.')
  else if Code = 'speech_model_path_encoding' then
    Result := UiText('The speech model path contains unsupported characters.')
  else if Code = 'speech_model_load_failed' then
    Result := UiText('Could not load the speech recognition model.')
  else if Code = 'speech_library_missing' then
    Result := UiText('The offline speech recognition component is not installed.')
  else if (Code = 'speech_library_load_failed') or (Code = 'speech_library_incompatible') then
    Result := UiText('Could not load the offline speech recognition component.')
  else if Code = 'speech_language_unsupported' then
    Result := UiText('Voice input supports Russian and English.')
  else if Code = 'speech_platform_unsupported' then
    Result := UiText('Voice input is not supported on this system.')
  else if Code = 'speech_no_speech' then
    Result := UiText('No speech recognized. The draft was not changed.')
  else if Code = 'speech_result_too_long' then
    Result := UiText('The phrase is too long. Record a shorter phrase.')
  else if Code = 'speech_audio_overrun' then
    Result := UiText('Recording fell behind. Try a shorter phrase.')
  else if Code = 'speech_voice_language_unavailable' then
    Result := UiText('No voice for this language is installed.')
  else if Code = 'speech_output_queue_full' then
    Result := UiText('Voice queue is full. The reply is still in the chat.')
  else if Code = 'speech_output_muted' then
    Result := UiText('Application sound is muted.')
  else if Code = 'speech_output_unavailable' then
    Result := UiText('No speech voice is available on this system.')
  else if Output then Result := UiText('Voice playback is unavailable.')
  else Result := UiText('Voice input is unavailable. Please try again.');
end;

procedure TViewAssistant.RefreshVoice;
var Data: TJSONObject; InputText, OutputText, OutputState, Code, Partial,
    Transcript, Draft, CaptionText: String;
  Connected, ActiveInput: Boolean; Level: Double;
begin
  if FMicrophone = nil then Exit;
  Connected := Assistant.Connected;
  { Snapshot updates the service; only then consume its completed transcript.
    This prevents acknowledging a new revision before reading its result. }
  Data := AssistantVoice.Snapshot;
  try
  if Connected and not FClosing and Exists and
    AssistantVoice.TakeTranscript(Transcript) then begin
    Transcript := Trim(Transcript);
    if Transcript <> '' then begin
      { Never replace a typed draft, including edits made during recognition.
        Keep all UTF-8 bytes even when the combined draft exceeds the send
        limit: the existing length check asks the user to shorten it. }
      Draft := FInput.Text;
      if (Draft <> '') and not (Draft[Length(Draft)] in [#9, #10, #13, ' ']) then
        Draft := Draft + ' ';
      FInput.Text := Draft + Transcript; FDraft := FInput.Text;
      InputChanged(nil);
      if Length(FInput.Text) > 4096 then
        FVoiceNotice := 'Voice text added. Shorten the draft before sending.'
      else FVoiceNotice := 'Voice text added. Review it and press Send.';
      FNeedFocus := OwnsKeyboard;
    end else FVoiceNotice := 'No speech recognized. The draft was not changed.';
  end;
    FVoiceRevision := AssistantVoice.Revision;
    FVoiceState := Data.Get('input_state', 'idle');
    ActiveInput := (FVoiceState = 'waiting_output') or (FVoiceState = 'loading') or
      (FVoiceState = 'listening') or (FVoiceState = 'recognizing');
    FMicrophone.Enabled := Connected and (ActiveInput or
      Data.Get('input_available', False) or (FVoiceState = 'error'));
    FReadReplies.Enabled := Connected;
    FReadReplies.Pressed := AssistantVoice.SpeakEnabled;
    if FReadReplies.Pressed then FReadReplies.Style := mbPrimary else FReadReplies.Style := mbSecondary;
    CaptionText := 'Microphone'; FMicrophone.Style := mbSecondary;
    FVoiceInputStatus.Color := MenuMuted;
    if not Connected then InputText := UiText('Connect an agent to use voice.')
    else if FVoiceState = 'waiting_output' then begin
      CaptionText := 'Cancel'; InputText := UiText('Stopping playback before recording...');
    end else if FVoiceState = 'loading' then begin
      CaptionText := 'Cancel'; InputText := UiText('Preparing the microphone...');
    end else if FVoiceState = 'listening' then begin
      CaptionText := 'Finish recording'; FMicrophone.Style := mbDanger;
      FVoiceInputStatus.Color := Vector4(1, 0.68, 0.62, 1);
      InputText := UiText('Recording...') + ' ' +
        TimeText(Data.Get('recording_ms', Int64(0)) / 1000.0);
      Partial := Trim(Data.Get('input_partial', ''));
      if Partial <> '' then InputText := InputText + #10 + Partial;
    end else if FVoiceState = 'recognizing' then begin
      CaptionText := 'Cancel'; InputText := UiText('Recognizing speech...');
    end else begin
      Code := Data.Get('input_error', '');
      if Code <> '' then InputText := VoiceErrorText(Code, False)
      else if FVoiceNotice <> '' then InputText := UiText(FVoiceNotice)
      else InputText := UiText('Dictation is added to your draft.');
    end;
    FMicrophone.Caption := UiText(CaptionText);
    FVoiceInputStatus.Caption := MenuSummary(InputText, FVoiceInputStatus.Font,
      FVoiceInputStatus.MaxWidth * UIScale, 2);
    FVoiceMeter.Exists := Connected and (FVoiceState = 'listening');
    Level := Data.Get('level', 0.0);
    if IsNan(Level) or IsInfinite(Level) then Level := 0;
    FVoiceLevel.Width := FVoiceMeter.Width * Sqrt(EnsureRange(Level, 0.0, 1.0));
    OutputState := Data.Get('output_state', 'idle');
    FStopSpeech.Enabled := Connected and ((OutputState = 'speaking') or (OutputState = 'loading'));
    Code := Data.Get('output_error', '');
    if (Code = '') and (Data.Get('voice_name', '') <> '') and
      not Data.Get('language_match', True) then Code := 'speech_voice_language_unavailable';
    if not AssistantVoice.SpeakEnabled then OutputText := UiText('Voice replies are off.')
    else if Code <> '' then OutputText := VoiceErrorText(Code, True)
    else if OutputState = 'loading' then OutputText := UiText('Preparing speech playback...')
    else if OutputState = 'speaking' then OutputText := UiText('Speaking...')
    else OutputText := UiText('Voice replies are on.');
    if AssistantVoice.SpeakEnabled and (Data.Get('voice_name', '') <> '') then
      OutputText := OutputText + AssistantSeparator + Data.Get('voice_name', '');
    FVoiceOutputStatus.Caption := MenuSummary(OutputText, FVoiceOutputStatus.Font,
      FVoiceOutputStatus.MaxWidth * UIScale, 2);
  finally Data.Free; end;
end;

procedure TViewAssistant.ClickMicrophone(Sender: TObject);
begin
  if not Assistant.Connected or not FMicrophone.Enabled then Exit;
  FVoiceNotice := '';
  try
    if FVoiceState = 'listening' then AssistantVoice.StopInput
    else if (FVoiceState = 'waiting_output') or (FVoiceState = 'loading') or
      (FVoiceState = 'recognizing') then AssistantVoice.CancelInput
    else begin FVoiceCancelledForFocus := False; AssistantVoice.StartInput; end;
    RefreshVoice;
  except on E: Exception do
    FVoiceInputStatus.Caption := UiText('Voice input is unavailable. Please try again.'); end;
end;

procedure TViewAssistant.ClickReadReplies(Sender: TObject);
begin
  if not Assistant.Connected then Exit;
  try
    AssistantVoice.SetSpeakEnabled(not AssistantVoice.SpeakEnabled); RefreshVoice;
  except on E: Exception do begin
    FReadReplies.Pressed := AssistantVoice.SpeakEnabled;
    FVoiceOutputStatus.Caption := UiText('Could not save the voice setting. Please try again.');
  end; end;
end;

procedure TViewAssistant.ClickStopSpeech(Sender: TObject);
begin AssistantVoice.StopSpeech; RefreshVoice; end;

procedure TViewAssistant.InputChanged(Sender: TObject);
begin
  if FInput = nil then Exit;
  if Sender = FInput then begin FVoiceNotice := ''; FVoiceRevision := High(QWord); end;
  FSend.Enabled := Assistant.Connected and (Trim(FInput.Text) <> '') and (Length(FInput.Text) <= 4096);
  if Length(FInput.Text) > 4096 then FError.Caption := UiText('Message is too long. Please shorten it.')
  else if (FSnapshot <> nil) and (FSnapshot.Get('pending_count', 0) > 0) then
    FError.Caption := UiText('Waiting for the assistant...')
  else FError.Caption := '';
end;

procedure TViewAssistant.ClickSend(Sender: TObject);
var Reason: String;
begin
  SyncAssistantContext(True);SyncDraftContext;
  if not FSend.Enabled then Exit;
  try
    Assistant.SendUserMessage(Trim(FInput.Text));
    FInput.Text := ''; FDraft := ''; FVoiceNotice := ''; RefreshConversation; ClickLatest(nil);
    FNeedFocus := True;
  except on E: Exception do begin
    if E.Message = 'assistant_not_connected' then Reason := 'Connect an agent before sending a message.'
    else if E.Message = 'assistant_queue_full' then Reason := 'The assistant has too many pending messages. Wait for a reply.'
    else if E.Message = 'assistant_invalid_text' then Reason := 'Enter a message of up to 4096 bytes.'
    else Reason := 'Could not send the message. Please try again.';
    FError.Caption := UiText(Reason);
  end; end;
end;

procedure TViewAssistant.ClickClose(Sender: TObject);
begin
  Close;
end;

procedure TViewAssistant.ClickDisconnect(Sender: TObject);
begin
  if (FLocalStatus <> nil) and FLocalStatus.Get('enabled', False) then DisableLocalMcp
  else begin AssistantVoice.CancelInput; Assistant.Disconnect; EndAssistantVoiceSession end;
  FConnectionNotice := '';
  RefreshConversation; RefreshVoice;
end;

procedure TViewAssistant.ClickLatest(Sender: TObject);
begin FScroll.Scroll := FScroll.ScrollMax; end;

procedure TViewAssistant.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited;
  if FClosing then Exit;
  AssistantVoice.Update;
  if Container.Focused then FVoiceCancelledForFocus := False;
  if not Container.Focused and not FVoiceCancelledForFocus and ((FVoiceState = 'waiting_output') or
    (FVoiceState = 'loading') or (FVoiceState = 'listening') or
    (FVoiceState = 'recognizing')) then begin
    { Cancel is asynchronous: the worker may stay in finalizing while it
      releases a model/device. Do not cancel and rebuild status every frame. }
    FVoiceCancelledForFocus := True;
    AssistantVoice.CancelInput;
    FVoiceNotice := 'Recording cancelled while the window was inactive.';
    RefreshVoice;
  end;
  if (Assistant.Revision <> FRevision) or (UiLanguage <> FLastLanguage) then RefreshConversation;
  FLocalElapsed := FLocalElapsed + SecondsPassed;
  if FLocalElapsed >= 0.5 then begin
    FLocalElapsed := 0;SyncAssistantContext;RefreshLocalConnection;
  end;
  FVoiceElapsed := FVoiceElapsed + SecondsPassed;
  if FVoiceElapsed >= 0.1 then begin
    FVoiceElapsed := 0;
    if FVoiceRevision <> AssistantVoice.Revision then RefreshVoice;
  end;
  FLiveElapsed := FLiveElapsed + SecondsPassed;
  if FLiveElapsed >= 1 then begin FLiveElapsed := 0; RefreshLiveStatus; end;
  FLatest.Exists := FScroll.ScrollMax - FScroll.Scroll > 24 / Max(0.65, Min(1, UIScale));
  FHint.Exists := not FLatest.Exists or (FPanel.Width >= 480 / Max(0.65, Min(1, UIScale)));
  if FNeedFocus then begin
    FNeedFocus := False; FKeyboardActive := True;
    FInput.Focused := True; Container.ForceCaptureInput := FInput;
  end;
  if OwnsKeyboard or FPanel.RenderRect.Contains(Container.MousePosition) then HandleInput := False;
end;

function TViewAssistant.PreviewPress(const Event: TInputPressRelease): Boolean;
begin
  if Event.EventType = itMouseButton then begin
    if not FPanel.RenderRect.Contains(Event.Position) then ReleaseKeyboard
    else begin
      FKeyboardActive := True;
      if FKeyboard <> nil then FKeyboard.Clear;
      Container.ForceCaptureInput := nil;
      if FInput.RenderRect.Contains(Event.Position) then begin
        FInput.Focused := True; Container.ForceCaptureInput := FInput;
      end;
    end;
  end;
  if not OwnsKeyboard then Exit(inherited);
  if Event.IsKey(keyEscape) then begin ClickClose(nil); Exit(True); end;
  if Event.IsKey(keyEnter) and (Container.ForceCaptureInput = FInput) then begin ClickSend(nil); Exit(True); end;
  if (FKeyboard <> nil) and FKeyboard.Handle(Event, Self) then Exit(True);
  Result := inherited;
end;

function TViewAssistant.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited;
  if Event.EventType = itKey then Result := Result or OwnsKeyboard
  else if FPanel.RenderRect.Contains(Event.Position) then begin
    Result := True;
    if Event.EventType = itMouseButton then Include(FPanelButtons, Event.MouseButton);
  end;
end;
function TViewAssistant.Release(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited;
  if Event.EventType = itKey then Result := Result or OwnsKeyboard
  else begin
    Result := Result or FPanel.RenderRect.Contains(Event.Position);
    if Event.EventType = itMouseButton then begin
      Result := Result or (Event.MouseButton in FPanelButtons);
      Exclude(FPanelButtons, Event.MouseButton);
    end;
  end;
end;
function TViewAssistant.Motion(const Event: TInputMotion): Boolean;
begin
  FPanelButtons := FPanelButtons * Event.Pressed;
  Result := inherited or (FPanelButtons <> []) or FPanel.RenderRect.Contains(Event.Position);
end;

procedure TViewAssistant.RenderOverChildren;
begin inherited; if FKeyboard <> nil then FKeyboard.Render; end;

end.
