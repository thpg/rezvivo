{ GameViewLogin — экран входа в VeloSite.

  Две вкладки:
    «Через сайт» (по умолчанию):
      device flow — игра не запрашивает пароль. Жмём «Continue in
      browser»: POST device/start, открываем verification_uri в
      системном браузере (пользователь уже залогинен на сайте —
      страница /link?code= подтверждает сама), поллим device/poll.
      По 200 — токены сохранены, переходим в меню.
    «По email/паролю»:
      простой логин. Поле email + поле пароля + кнопка «Войти».

  Все сетевые вызовы блокирующие, поэтому делаются в фоновом потоке
  TLoginThread, чтобы UI не зависал. Поток постит результат через
  ApplicationProperties.OnUpdate в главный поток (TCastleView.Update). }
unit GameViewLogin;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses GameMenuTheme,
  Classes, SysUtils, SyncObjs,
  CastleComponentSerialize, CastleUIControls, CastleControls,
  CastleVectors, CastleColors, CastleKeysMouse,
  VeloSiteAPI;

type
  TLoginMode = (lmDevice, lmPassword);

  { Состояние асинхронной операции login/poll. Главный поток читает
    в Update, фоновый поток пишет под FLock. }
  TLoginAsyncState = (lasIdle, lasRunning, lasSucceeded, lasFailed);

  { Фоновый поток для одного «выстрела»: либо Login(email, pass),
    либо DeviceStart, либо DevicePoll. }
  TLoginAction = (laLoginPassword, laDeviceStart, laDevicePoll);

  TLoginThread = class(TThread)
  private
    FAction:        TLoginAction;
    FEmail:         String;
    FPassword:      String;
    FDeviceCode:    String;
    FLock:          TCriticalSection;
    FState:         TLoginAsyncState;
    FErrorMessage:  String;
    FResultDevice:  TVeloSiteDeviceCode;
    FResultPolled:  Boolean;
    FAccountToken:QWord;
  protected
    procedure Execute; override;
  public
    property State:  TLoginAsyncState read FState;
    property Action: TLoginAction     read FAction;

    constructor Create(AAction: TLoginAction);
    destructor  Destroy; override;
    procedure Start;reintroduce;

    procedure SetCredentials(const AEmail, APassword: String);
    procedure SetDeviceCode(const ACode: String);

    function  TakeError: String;
    function  TakeDevice: TVeloSiteDeviceCode;
    function  TakePolled: Boolean;
  end;

  TViewLogin = class(TCastleView)
  published
    LabelTitle:  TCastleLabel;
    ButtonBack:  TCastleButton;
    FormHost:    TCastleUserInterface;
    LabelStatus: TCastleLabel;
  private
    FMode: TLoginMode;

    { Tab-кнопки }
    FTabDevice:   TCastleButton;
    FTabPassword: TCastleButton;

    { Содержимое формы — пересоздаётся при смене вкладки }
    FFormContent: TCastleUserInterface;

    { Device flow }
    FButtonGetCode: TCastleButton;
    FLabelUserCode: TCastleLabel;
    FLabelHint:     TCastleLabel;
    FCurrentDevice: TVeloSiteDeviceCode;
    FPollTimer:     Single;          { секунды до следующего poll }
    FPollExpiresAt: TDateTime;       { когда код протухнет }
    FPolling:       Boolean;

    { Email/password }
    FEditEmail:    TCastleEdit;
    FEditPassword: TCastleEdit;
    FButtonLogin:  TCastleButton;

    { Async }
    FBackground: TLoginThread;

    procedure ClickBack(Sender: TObject);
    procedure ClickTabDevice(Sender: TObject);
    procedure ClickTabPassword(Sender: TObject);
    procedure ClickGetCode(Sender: TObject);
    procedure ClickLogin(Sender: TObject);

    procedure SwitchMode(AMode: TLoginMode);
    procedure RebuildForm;
    procedure BuildDeviceForm;
    procedure BuildPasswordForm;
    function  DeviceVerificationUrl: String;
    procedure OpenBrowserForDevice;

    procedure SetStatus(const AText: String; AIsError: Boolean);
    procedure HandleAsyncCompletion;
    procedure FinishLoginSuccess;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Start; override;
    function Press(const Event:TInputPressRelease):Boolean; override;
    procedure Stop; override;
    procedure Update(const SecondsPassed: Single;
      var HandleInput: Boolean); override;
  end;

var
  ViewLogin: TViewLogin;

implementation

uses UiTranslations,
  CastleLog, CastleApplicationProperties, CastleOpenDocument,
  GameViewMenu, GameLocalization,GameAccountChange;

{ ══════════════════════════════════════════════════════════════════
  TLoginThread
  ══════════════════════════════════════════════════════════════════ }

constructor TLoginThread.Create(AAction: TLoginAction);
begin
  inherited Create(True);   { suspended }
  FreeOnTerminate := False;
  FAction := AAction;
  FLock := TCriticalSection.Create;
  FState := lasIdle;
end;

destructor TLoginThread.Destroy;
begin
  if not Suspended then WaitFor;
  EndAccountChange(FAccountToken);
  FLock.Free;
  inherited;
end;

procedure TLoginThread.SetCredentials(const AEmail, APassword: String);
begin
  FEmail := AEmail;
  FPassword := APassword;
end;

procedure TLoginThread.SetDeviceCode(const ACode: String);
begin
  FDeviceCode := ACode;
end;

procedure TLoginThread.Start;
begin
  try
    if FAction in[laLoginPassword,laDevicePoll]then FAccountToken:=BeginAccountChange;
    inherited Start;
    if Suspended then raise EThread.Create('Could not start account request');
  except on E:Exception do begin
    EndAccountChange(FAccountToken);FAccountToken:=0;
    FErrorMessage:=E.Message;FState:=lasFailed;
  end;end;
end;

procedure TLoginThread.Execute;
begin
  try
  FLock.Enter;
  try
    FState := lasRunning;
  finally
    FLock.Leave;
  end;

  try
    case FAction of
      laLoginPassword:
        VeloSite.Login(FEmail, FPassword);
      laDeviceStart:
        FResultDevice := VeloSite.DeviceStart;
      laDevicePoll:
        FResultPolled := VeloSite.DevicePoll(FDeviceCode);
    end;
    FLock.Enter;
    try
      FState := lasSucceeded;
    finally
      FLock.Leave;
    end;
  except
    on E: Exception do
    begin
      FLock.Enter;
      try
        FErrorMessage := E.Message;
        FState := lasFailed;
      finally
        FLock.Leave;
      end;
    end;
  end;
  finally EndAccountChange(FAccountToken);FAccountToken:=0;end;
end;

function TLoginThread.TakeError: String;
begin
  FLock.Enter;
  try
    Result := FErrorMessage;
  finally
    FLock.Leave;
  end;
end;

function TLoginThread.TakeDevice: TVeloSiteDeviceCode;
begin
  Result := FResultDevice;
end;

function TLoginThread.TakePolled: Boolean;
begin
  Result := FResultPolled;
end;

{ ══════════════════════════════════════════════════════════════════
  TViewLogin
  ══════════════════════════════════════════════════════════════════ }

constructor TViewLogin.Create(AOwner: TComponent);
begin
  inherited;
  DesignUrl := 'castle-data:/gameviewlogin.castle-user-interface';
  FMode := lmDevice;
end;

procedure TViewLogin.Start;
begin
  inherited;
  LocalizeDesignedUi(Self);
  TCastleRectangleControl(DesignedComponent('Background')).Color:=MenuBackground;
  LabelTitle.CustomFont:=MenuFont(True);LabelTitle.FontScale:=1;LabelTitle.FontSize:=32;
  LabelStatus.CustomFont:=MenuFont;LabelStatus.FontScale:=1;LabelStatus.FontSize:=16;
  if Assigned(LabelTitle) then BindUiText(LabelTitle, 'Sign in to VeloSite');
  if Assigned(ButtonBack) then BindUiText(ButtonBack, 'Back');

  if Assigned(ButtonBack) then ButtonBack.OnClick := @ClickBack;

  { Сбрасываем фоновый поток если вдруг остался от предыдущего входа. }
  FreeAndNil(FBackground);
  FPolling := False;
  FPollTimer := 0;
  SetStatus('', False);

  RebuildForm;
end;

procedure TViewLogin.Stop;
begin
  if Assigned(FBackground) then
  begin
    FBackground.WaitFor;     { не убиваем поток на лету }
    FreeAndNil(FBackground);
  end;
  inherited;
end;

function TViewLogin.Press(const Event:TInputPressRelease):Boolean;
begin
  if Event.IsKey(keyEscape)then begin ClickBack(nil);Exit(True);end;
  Result:=inherited;
end;
procedure TViewLogin.ClickBack(Sender: TObject);
begin
  ViewMenu.CloseChildView(Self,'');
end;

procedure TViewLogin.ClickTabDevice(Sender: TObject);
begin
  SwitchMode(lmDevice);
end;

procedure TViewLogin.ClickTabPassword(Sender: TObject);
begin
  SwitchMode(lmPassword);
end;

procedure TViewLogin.SwitchMode(AMode: TLoginMode);
begin
  if FMode = AMode then Exit;
  FMode := AMode;
  FPolling := False;
  SetStatus('', False);
  RebuildForm;
end;

procedure TViewLogin.RebuildForm;
var
  TabsRow: TCastleHorizontalGroup;
begin
  if not Assigned(FormHost) then Exit;

  FormHost.ClearControls;
  FFormContent := nil;

  { Tabs row at top of form }
  TabsRow := TCastleHorizontalGroup.Create(FreeAtStop);
  TabsRow.Spacing := 4;
  TabsRow.Anchor(hpMiddle);
  TabsRow.Anchor(vpTop, 0);
  FormHost.InsertFront(TabsRow);

  FTabDevice := TMenuButton.Create(FreeAtStop);
  BindUiText(FTabDevice, 'Via website');
  FTabDevice.Toggle := True;
  FTabDevice.Pressed := FMode = lmDevice;
  FTabDevice.MinWidth := 200;
  FTabDevice.PaddingHorizontal := 16;
  FTabDevice.PaddingVertical := 10;
  FTabDevice.OnClick := @ClickTabDevice;
  TabsRow.InsertFront(FTabDevice);

  FTabPassword := TMenuButton.Create(FreeAtStop);
  BindUiText(FTabPassword, 'Email and password');
  FTabPassword.Toggle := True;
  FTabPassword.Pressed := FMode = lmPassword;
  FTabPassword.MinWidth := 200;
  FTabPassword.PaddingHorizontal := 16;
  FTabPassword.PaddingVertical := 10;
  FTabPassword.OnClick := @ClickTabPassword;
  TabsRow.InsertFront(FTabPassword);

  case FMode of
    lmDevice:   BuildDeviceForm;
    lmPassword: BuildPasswordForm;
  end;
end;

procedure TViewLogin.BuildDeviceForm;
var
  Hint: TCastleLabel;
begin
  FFormContent := TCastleUserInterface.Create(FreeAtStop);
  FFormContent.Width := FormHost.EffectiveWidth;
  FFormContent.Height := 400;
  FFormContent.Anchor(hpMiddle);
  FFormContent.Anchor(vpTop, -80);
  FormHost.InsertFront(FFormContent);

  Hint := TMenuLabel.Create(FreeAtStop);
  Hint.Caption :=
    T('Secure sign-in without sharing your password with the game.') + LineEnding +
    T('Log in on the website in your default browser first. Then click the button — the game will open a confirmation page and sign you in.');
  Hint.FontScale := 1.0;
  Hint.MaxWidth := 720;
  Hint.Color := Vector4(0.85, 0.85, 0.9, 1);
  Hint.Anchor(hpMiddle);
  Hint.Anchor(vpTop, 0);
  FFormContent.InsertFront(Hint);

  FButtonGetCode := TMenuButton.Create(FreeAtStop);
  TMenuButton(FButtonGetCode).Style:=mbPrimary;TMenuButton(FButtonGetCode).AutoIcon:=False;
  BindUiText(FButtonGetCode, 'Continue in browser');
  FButtonGetCode.MinWidth := 280;
  FButtonGetCode.PaddingHorizontal := 24;
  FButtonGetCode.PaddingVertical := 14;
  FButtonGetCode.FontScale := 1.2;
  FButtonGetCode.OnClick := @ClickGetCode;
  FButtonGetCode.Anchor(hpMiddle);
  FButtonGetCode.Anchor(vpTop, -110);
  FFormContent.InsertFront(FButtonGetCode);

  FLabelUserCode := TMenuLabel.Create(FreeAtStop);
  FLabelUserCode.Caption := '';
  FLabelUserCode.FontScale := 1.1;
  FLabelUserCode.Color := Vector4(0.75, 0.8, 0.85, 1);
  FLabelUserCode.Anchor(hpMiddle);
  FLabelUserCode.Anchor(vpTop, -190);
  FFormContent.InsertFront(FLabelUserCode);

  FLabelHint := TMenuLabel.Create(FreeAtStop);
  FLabelHint.Caption := '';
  FLabelHint.FontScale := 1.0;
  FLabelHint.Color := Vector4(0.7, 0.85, 0.95, 1);
  FLabelHint.Anchor(hpMiddle);
  FLabelHint.Anchor(vpTop, -240);
  FFormContent.InsertFront(FLabelHint);
end;

procedure TViewLogin.BuildPasswordForm;
var
  LabelEmail, LabelPass: TCastleLabel;
begin
  FFormContent := TCastleUserInterface.Create(FreeAtStop);
  FFormContent.Width := FormHost.EffectiveWidth;
  FFormContent.Height := 400;
  FFormContent.Anchor(hpMiddle);
  FFormContent.Anchor(vpTop, -80);
  FormHost.InsertFront(FFormContent);

  LabelEmail := TMenuLabel.Create(FreeAtStop);
  BindUiText(LabelEmail, 'Email:');
  LabelEmail.FontScale := 1.1;
  LabelEmail.Color := Vector4(0.85, 0.85, 0.9, 1);
  LabelEmail.Anchor(hpLeft, 80);
  LabelEmail.Anchor(vpTop, -10);
  FFormContent.InsertFront(LabelEmail);

  FEditEmail := TMenuEdit.Create(FreeAtStop);
  FEditEmail.Width := 440;
  FEditEmail.Anchor(hpLeft, 180);
  FEditEmail.Anchor(vpTop, -10);
  FFormContent.InsertFront(FEditEmail);

  LabelPass := TMenuLabel.Create(FreeAtStop);
  BindUiText(LabelPass, 'Password:');
  LabelPass.FontScale := 1.1;
  LabelPass.Color := Vector4(0.85, 0.85, 0.9, 1);
  LabelPass.Anchor(hpLeft, 80);
  LabelPass.Anchor(vpTop, -70);
  FFormContent.InsertFront(LabelPass);

  FEditPassword := TMenuEdit.Create(FreeAtStop);
  FEditPassword.Width := 440;
  FEditPassword.PasswordChar := '*';
  FEditPassword.Anchor(hpLeft, 180);
  FEditPassword.Anchor(vpTop, -70);
  FFormContent.InsertFront(FEditPassword);

  FButtonLogin := TMenuButton.Create(FreeAtStop);
  TMenuButton(FButtonLogin).Style:=mbPrimary;TMenuButton(FButtonLogin).AutoIcon:=False;
  BindUiText(FButtonLogin, 'Sign in');
  FButtonLogin.MinWidth := 240;
  FButtonLogin.PaddingHorizontal := 24;
  FButtonLogin.PaddingVertical := 14;
  FButtonLogin.FontScale := 1.2;
  FButtonLogin.OnClick := @ClickLogin;
  FButtonLogin.Anchor(hpMiddle);
  FButtonLogin.Anchor(vpTop, -150);
  FFormContent.InsertFront(FButtonLogin);
end;

procedure TViewLogin.SetStatus(const AText: String; AIsError: Boolean);
begin
  if not Assigned(LabelStatus) then Exit;
  LabelStatus.Caption := AText;
  if AIsError then
    LabelStatus.Color := Vector4(1.0, 0.5, 0.45, 1)
  else
    LabelStatus.Color := Vector4(0.6, 0.95, 0.7, 1);
end;

function TViewLogin.DeviceVerificationUrl: String;
begin
  Result := Trim(FCurrentDevice.VerificationUrl);
  if (Pos('code=', LowerCase(Result)) = 0) and (FCurrentDevice.UserCode <> '') then
  begin
    if Result = '' then
      Result := Trim(VeloSite.BaseUrl) + '/link';
    if Pos('?', Result) > 0 then
      Result := Result + '&code=' + FCurrentDevice.UserCode
    else
      Result := Result + '?code=' + FCurrentDevice.UserCode;
  end;
end;

procedure TViewLogin.OpenBrowserForDevice;
var
  Url: String;
begin
  Url := DeviceVerificationUrl;
  if Url = '' then
  begin
    SetStatus(T('Could not open the browser. Open this link:'), True);
    Exit;
  end;
  if OpenUrl(Url) then
  begin
    if Assigned(FLabelHint) then
      BindUiText(FLabelHint, 'Confirm in the browser if asked, then return here. The game is waiting...');
    SetStatus(T('Waiting for confirmation...'), False);
  end
  else
  begin
    if Assigned(FLabelHint) then
      FLabelHint.Caption := T('Could not open the browser. Open this link:') +
        LineEnding + Url;
    SetStatus(T('Waiting for confirmation...'), False);
  end;
end;

procedure TViewLogin.ClickGetCode(Sender: TObject);
var Blocked:String;
begin
  Blocked:=ViewMenu.AccountChangeError;
  if Blocked<>''then begin SetStatus(Blocked,True);Exit;end;
  { Повторное нажатие во время ожидания — снова открыть браузер. }
  if FPolling and (DeviceVerificationUrl <> '') then
  begin
    OpenBrowserForDevice;
    Exit;
  end;
  if Assigned(FBackground) then Exit;     { уже что-то делаем }

  SetStatus(T('Opening the website...'), False);
  FButtonGetCode.Enabled := False;
  if Assigned(FLabelUserCode) then FLabelUserCode.Caption := '';
  if Assigned(FLabelHint) then FLabelHint.Caption := '';

  FBackground := TLoginThread.Create(laDeviceStart);
  FBackground.Start;
end;

procedure TViewLogin.ClickLogin(Sender: TObject);
var Blocked:String;
begin
  if Assigned(FBackground) then Exit;
  Blocked:=ViewMenu.AccountChangeError;
  if Blocked<>''then begin SetStatus(Blocked,True);Exit;end;
  if (FEditEmail.Text = '') or (FEditPassword.Text = '') then
  begin
    SetStatus(T('Fill in email and password'), True);
    Exit;
  end;

  SetStatus(T('Signing in...'), False);
  FButtonLogin.Enabled := False;

  FBackground := TLoginThread.Create(laLoginPassword);
  FBackground.SetCredentials(FEditEmail.Text, FEditPassword.Text);
  FBackground.Start;
end;

procedure TViewLogin.HandleAsyncCompletion;
var
  Action: TLoginAction;
  Err: String;
  Polled: Boolean;
begin
  if not Assigned(FBackground) then Exit;
  if FBackground.State in [lasIdle, lasRunning] then Exit;

  Action := FBackground.Action;

  if FBackground.State = lasFailed then
  begin
    Err := FBackground.TakeError;
    case Action of
      laDeviceStart:
        begin
          SetStatus(T('Failed to start website sign-in: ') + Err, True);
          if Assigned(FButtonGetCode) then FButtonGetCode.Enabled := True;
        end;
      laDevicePoll:
        begin
          SetStatus(T('Polling error: ') + Err, True);
          FPolling := False;
          if Assigned(FButtonGetCode) then
          begin
            BindUiText(FButtonGetCode, 'Continue in browser');
            FButtonGetCode.Enabled := True;
          end;
        end;
      laLoginPassword:
        begin
          SetStatus(T('Sign in failed: ') + Err, True);
          if Assigned(FButtonLogin) then FButtonLogin.Enabled := True;
        end;
    end;
    FreeAndNil(FBackground);
    Exit;
  end;

  { Success path }
  case Action of
    laDeviceStart:
      begin
        FCurrentDevice := FBackground.TakeDevice;
        FreeAndNil(FBackground);

        if FCurrentDevice.Interval <= 0 then
          FCurrentDevice.Interval := 5;
        if FCurrentDevice.ExpiresIn <= 0 then
          FCurrentDevice.ExpiresIn := 900;
        FPollExpiresAt := Now + (FCurrentDevice.ExpiresIn / 86400.0);
        FPollTimer := FCurrentDevice.Interval;
        FPolling := True;

        if Assigned(FButtonGetCode) then
        begin
          BindUiText(FButtonGetCode, 'Open browser again');
          FButtonGetCode.Enabled := True;
        end;
        OpenBrowserForDevice;
      end;
    laDevicePoll:
      begin
        Polled := FBackground.TakePolled;
        FreeAndNil(FBackground);
        if Polled then
          FinishLoginSuccess
        else
          ;     { ещё pending — следующий tick запустит новый poll }
      end;
    laLoginPassword:
      begin
        FreeAndNil(FBackground);
        FinishLoginSuccess;
      end;
  end;
end;

procedure TViewLogin.FinishLoginSuccess;
begin
  SetStatus(T('Success! Loading profile...'), False);
  try
    VeloSite.RefreshProfile;
  except
    on E: Exception do
      WritelnLog('Login', 'RefreshProfile failed (non-fatal): ' + E.Message);
  end;
  ViewMenu.CloseChildView(Self,'');
end;

procedure TViewLogin.Update(const SecondsPassed: Single;
  var HandleInput: Boolean);
var Blocked:String;
begin
  inherited;

  HandleAsyncCompletion;

  { Polling tick (только в device-режиме) }
  if FPolling and (FMode = lmDevice) and not Assigned(FBackground) then
  begin
    Blocked:=ViewMenu.AccountChangeError;
    if Blocked<>''then begin FPolling:=False;SetStatus(Blocked,True);Exit;end;
    if Now > FPollExpiresAt then
    begin
      FPolling := False;
      SetStatus(T('Sign-in expired. Try again.'), True);
      if Assigned(FLabelUserCode) then FLabelUserCode.Caption := '';
      if Assigned(FButtonGetCode) then
      begin
        BindUiText(FButtonGetCode, 'Continue in browser');
        FButtonGetCode.Enabled := True;
      end;
      Exit;
    end;

    FPollTimer := FPollTimer - SecondsPassed;
    if FPollTimer <= 0 then
    begin
      FPollTimer := FCurrentDevice.Interval;
      FBackground := TLoginThread.Create(laDevicePoll);
      FBackground.SetDeviceCode(FCurrentDevice.DeviceCode);
      FBackground.Start;
    end;
  end;
end;

end.
