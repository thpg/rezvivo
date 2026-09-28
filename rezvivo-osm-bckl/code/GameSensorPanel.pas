{ GameSensorPanel — визуальная панель выбора и отображения датчиков.

  4 колонки (Power, Cadence, Speed, HR) — в каждой карточки
  найденных датчиков этого типа. Клик по карточке назначает
  или снимает датчик в активный слот DeviceService.

  Цвета:
    Активный + подключён  — тёплый оранжево-янтарный
    Подключён, не активен  — тёмно-серый
    Отключён               — очень тёмный, приглушённый текст }
unit GameSensorPanel;

{$mode objfpc}{$H+}

interface

uses GameMenuTheme,
  Classes, SysUtils, fgl,
  CastleUIControls, CastleControls, CastleVectors, CastleColors,
  GameDeviceService, GameDeviceTypes, GameDeviceSensor, TrainerData;

type
  { Wrappers own their root controls; descendants belong to that root.
    AOwner parameters remain for existing callers, but UI lifetime is
    tied to the wrapper, including removal from a parent control. }
  { Одна карточка сенсора }
  TSensorCard = class
  private
    FSensor: TDeviceSensor;
    FEntry: TGameDeviceEntry;
    FKind: TSensorKind;

    FButton: TCastleButton;      { кликабельная подложка }
    FLabelName: TCastleLabel;
    FLabelTransport: TCastleLabel;
    FLabelValue: TCastleLabel;
    FLabelState: TCastleLabel;
    FLamp: TCastleRectangleControl; { индикатор приёма данных }

    procedure HandleClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent;
      ASensor: TDeviceSensor; AEntry: TGameDeviceEntry; AKind: TSensorKind);
    destructor Destroy; override;
    procedure UpdateVisuals;
    property Button: TCastleButton read FButton;
    property Sensor: TDeviceSensor read FSensor;
  end;

  TSensorCardList = specialize TFPGObjectList<TSensorCard>;

  { Колонка одного типа сенсоров }
  TSensorColumn = class
  private
    FKind: TSensorKind;
    FRoot: TCastleUserInterface;
    FHeaderBg: TCastleRectangleControl;
    FHeaderLabel: TCastleLabel;
    FCardsHost: TCastleUserInterface;
    FCards: TSensorCardList;
    FWidth: Single;
    FNoneButton: TMenuButton;
    FSelectionLabel: TMenuLabel;
    procedure ClearSelection(Sender: TObject);
  public
    constructor Create(AOwner: TComponent; AKind: TSensorKind;
      AWidth: Single);
    destructor Destroy; override;
    procedure SetWidth(const AWidth: Single);
    procedure Rebuild(AOwner: TComponent);
    procedure UpdateAll;
    property Root: TCastleUserInterface read FRoot;
  end;

  { Вся панель с 4 колонками }
  TSensorPanel = class
  private
    FParent: TCastleUserInterface;
    FRoot: TCastleUserInterface;
    FColumns: array[TSensorKind] of TSensorColumn;
    FColumnWidth: Single;
    FControlRow: TMenuFlow;
    FControlLabel: TMenuLabel;
    FControlOwner: TComponent;
    FControlSignature: String;
    procedure ChooseControl(Sender: TObject);
    procedure RefreshControl;
  public
    constructor Create(AOwner: TComponent);
    destructor Destroy; override;

    procedure Build(AParent: TCastleUserInterface);
    procedure Layout;
    procedure Rebuild;
    procedure Refresh;

    property Root: TCastleUserInterface read FRoot;
  end;

implementation

uses Math, UiTranslations, AppSettings;


const
  { ── Размеры ── }
  CardHeight = 100;
  CardGap = 10;
  CardPadX = 10;
  HeaderHeight = 32;
  ColumnGap = 16;

  SENSOR_HEADERS: array[TSensorKind] of string = (
    'HR', 'POWER', 'CADENCE', 'SPEED'
  );

{ ═══════════════════════════════════════════════════════════════════
  TSensorCard
  ═══════════════════════════════════════════════════════════════════ }

constructor TSensorCard.Create(AOwner: TComponent;
  ASensor: TDeviceSensor; AEntry: TGameDeviceEntry; AKind: TSensorKind);
begin
  inherited Create;
  FSensor := ASensor;
  FEntry := AEntry;
  FKind := AKind;

  { Кнопка-подложка }
  FButton := TMenuButton.Create(nil);
  FButton.Caption := '';
  FButton.Height := CardHeight;
  FButton.AutoSize := False;
  FButton.AutoSizeWidth := False;
  FButton.AutoSizeHeight := False;
  FButton.CustomColorNormal := Vector4(0.12, 0.12, 0.13, 1.0);
  FButton.CustomColorFocused := Vector4(0.18, 0.18, 0.20, 1.0);
  FButton.CustomColorPressed := Vector4(0.25, 0.25, 0.28, 1.0);
  FButton.OnClick := @HandleClick;

  { Имя устройства — верхняя строка }
  FLabelName := TMenuLabel.Create(FButton);
  FLabelName.Anchor(hpLeft, CardPadX);
  FLabelName.Anchor(vpTop, -6);
  FLabelName.FontScale := 0.85;
  FLabelName.Color := Vector4(1, 1, 1, 1);
  FButton.InsertFront(FLabelName);

  { Тип транспорта — вторая строка }
  FLabelTransport := TMenuLabel.Create(FButton);
  FLabelTransport.Anchor(hpLeft, CardPadX);
  FLabelTransport.Anchor(vpTop, -26);
  FLabelTransport.FontScale := 0.8;
  FLabelTransport.Color := Vector4(0.5, 0.5, 0.5, 1);
  FButton.InsertFront(FLabelTransport);

  { Статус — правый верхний угол }
  FLabelState := TMenuLabel.Create(FButton);
  FLabelState.Anchor(hpRight, -CardPadX);
  FLabelState.Anchor(vpTop, -30);
  FLabelState.FontScale := 0.75;
  FLabelState.Color := Vector4(0.5, 0.5, 0.5, 1);
  FButton.InsertFront(FLabelState);

  { Текущее значение — нижняя строка, крупно }
  FLabelValue := TMenuLabel.Create(FButton);
  FLabelValue.Anchor(hpLeft, CardPadX);
  FLabelValue.Anchor(vpTop, -62);
  FLabelValue.FontScale := 1.25;
  FLabelValue.Color := Vector4(1.0, 0.92, 0.6, 1);
  FButton.InsertFront(FLabelValue);

  { Индикатор приёма данных — маленький кружок справа внизу }
  FLamp := TCastleRectangleControl.Create(FButton);
  FLamp.Width := 8;
  FLamp.Height := 8;
  FLamp.Anchor(hpRight, -CardPadX);
  FLamp.Anchor(vpBottom, 8);
  FLamp.Color := Vector4(0.2, 0.2, 0.2, 1);
  FLamp.Exists := False;
  FButton.InsertFront(FLamp);

  UpdateVisuals;
end;

destructor TSensorCard.Destroy;
begin
  FreeAndNil(FButton);
  inherited;
end;

procedure TSensorCard.HandleClick(Sender: TObject);
begin
  if not Assigned(DeviceService) then Exit;

  FSensor := FEntry.FindSensor(FKind);
  if FSensor = nil then Exit;
  if DeviceService.IsSensorSelected(FKind, FEntry) then
    DeviceService.AssignSensor(FKind, nil)
  else
  begin
    DeviceService.AssignSensor(FKind, FSensor);
    if FEntry.ConnectionState in [gdcsDisconnected, gdcsError] then
      DeviceService.ConnectDevice(FEntry);
  end;
end;

procedure TSensorCard.UpdateVisuals;
var
  IsActive, IsConnected, IsStale: Boolean;
  DevName: string;
  Age: Double;
  TransColor: TCastleColor;
const
  STALE_TIMEOUT = 10.0; { seconds without data = signal lost }
begin
  if not Assigned(FEntry) then Exit;
  { Reconnecting rebuilds the entry's sensor objects. Never dereference the
    pointer retained by a card from before that reconnect. }
  FSensor := FEntry.FindSensor(FKind);
  if FSensor = nil then
  begin
    FLabelValue.Caption := '';
    BindUiText(FLabelState, 'offline');
    FLamp.Exists := False;
    Exit;
  end;

  IsConnected := (FEntry.ConnectionState = gdcsConnected);
  IsActive := Assigned(DeviceService) and DeviceService.IsSensorSelected(FKind, FEntry);
  Age := FSensor.DataAgeSec;
  IsStale := IsConnected and FSensor.HasData and (Age > STALE_TIMEOUT);

  { Имя }
  DevName := Trim(FEntry.DeviceInfo.Name);
  if DevName = '' then
    DevName := FEntry.DeviceInfo.Address;
  if DevName = '' then
    DevName := 'Unknown';
  FLabelName.Caption := MenuEllipsis(DevName, FLabelName.Font,
    (FButton.EffectiveWidth - 2 * CardPadX) * FLabelName.UIScale);

  { Транспорт }
  FLabelTransport.Caption := FEntry.TransportLabel;

  { Статус }
  if IsStale then
  begin
    BindUiText(FLabelState, 'SIGNAL LOST');
    FLabelState.Color := Vector4(1.0, 0.3, 0.3, 1);
  end
  else if IsActive and IsConnected then
  begin
    BindUiText(FLabelState, 'ACTIVE');
    FLabelState.Color := Vector4(0.3, 1.0, 0.3, 1);
  end
  else if IsConnected then
  begin
    if not FSensor.HasData then
    begin
      BindUiText(FLabelState, 'waiting...');
      FLabelState.Color := Vector4(0.7, 0.7, 0.3, 1);
    end
    else
    begin
      BindUiText(FLabelState, 'connected');
      FLabelState.Color := Vector4(0.5, 0.5, 0.5, 1);
    end;
  end
  else if FEntry.ConnectionState = gdcsConnecting then
  begin
    BindUiText(FLabelState, 'connecting...');
    FLabelState.Color := Vector4(0.7, 0.7, 0.3, 1);
  end
  else
  begin
    BindUiText(FLabelState, 'offline');
    FLabelState.Color := Vector4(0.4, 0.4, 0.4, 1);
  end;

  { Значение }
  if IsStale then
  begin
    FLabelValue.Caption := FSensor.FormatInstant;
    FLabelValue.Color := Vector4(0.5, 0.25, 0.25, 1); { dimmed red }
  end
  else if IsActive and IsConnected and FSensor.HasData then
  begin
    FLabelValue.Caption := FSensor.FormatInstant;
    FLabelValue.Color := Vector4(1.0, 1.0, 1.0, 1);
  end
  else
  begin
    FLabelValue.Caption := '--';
    FLabelValue.Color := Vector4(0.4, 0.4, 0.4, 1);
  end;

  { Цвет карточки }
  if IsStale then
  begin
    { Dark red tint — device was active but signal lost }
    FButton.CustomColorNormal := Vector4(0.35, 0.10, 0.10, 1.0);
    FButton.CustomColorFocused := Vector4(0.42, 0.14, 0.14, 1.0);
    FButton.CustomColorPressed := Vector4(0.28, 0.08, 0.08, 1.0);
    FLabelName.Color := Vector4(0.85, 0.55, 0.55, 1);
    TransColor := FEntry.TransportLabelColor;
    FLabelTransport.Color := Vector4(TransColor.X * 0.55,
      TransColor.Y * 0.55, TransColor.Z * 0.55, 1);
  end
  else if IsActive and IsConnected then
  begin
    FButton.CustomColorNormal := Vector4(0.65, 0.40, 0.08, 1.0);
    FButton.CustomColorFocused := Vector4(0.75, 0.48, 0.12, 1.0);
    FButton.CustomColorPressed := Vector4(0.55, 0.35, 0.06, 1.0);
    FLabelName.Color := Vector4(1, 1, 1, 1);
    FLabelTransport.Color := FEntry.TransportLabelColor;
  end
  else if IsConnected then
  begin
    FButton.CustomColorNormal := Vector4(0.20, 0.20, 0.22, 1.0);
    FButton.CustomColorFocused := Vector4(0.26, 0.26, 0.28, 1.0);
    FButton.CustomColorPressed := Vector4(0.30, 0.30, 0.33, 1.0);
    FLabelName.Color := Vector4(0.85, 0.85, 0.85, 1);
    TransColor := FEntry.TransportLabelColor;
    FLabelTransport.Color := Vector4(TransColor.X * 0.7,
      TransColor.Y * 0.7, TransColor.Z * 0.7, 1);
  end
  else
  begin
    FButton.CustomColorNormal := Vector4(0.12, 0.12, 0.13, 1.0);
    FButton.CustomColorFocused := Vector4(0.16, 0.16, 0.18, 1.0);
    FButton.CustomColorPressed := Vector4(0.20, 0.20, 0.22, 1.0);
    FLabelName.Color := Vector4(0.45, 0.45, 0.45, 1);
    TransColor := FEntry.TransportLabelColor;
    FLabelTransport.Color := Vector4(TransColor.X * 0.45,
      TransColor.Y * 0.45, TransColor.Z * 0.45, 1);
  end;

  { Индикатор приёма данных: моргает 0.5/0.5 если данные поступают }
  if IsConnected and (FSensor.LastUpdate > 0) and (Age < 3.0) then
  begin
    FLamp.Exists := True;
    { Blink: 0.5s on (green), 0.5s off (dim) }
    if (Trunc(Now * 86400.0 * 2) mod 2) = 0 then
      FLamp.Color := Vector4(0.1, 0.9, 0.1, 1)
    else
      FLamp.Color := Vector4(0.15, 0.15, 0.15, 1);
  end
  else
    FLamp.Exists := False;
end;

{ ═══════════════════════════════════════════════════════════════════
  TSensorColumn
  ═══════════════════════════════════════════════════════════════════ }

constructor TSensorColumn.Create(AOwner: TComponent; AKind: TSensorKind;
  AWidth: Single);
begin
  inherited Create;
  FKind := AKind;
  FWidth := AWidth;
  FCards := TSensorCardList.Create(True);

  FRoot := TCastleUserInterface.Create(nil);
  FRoot.Width := AWidth;
  FRoot.Height := HeaderHeight;
  FRoot.Anchor(vpTop);

  { Заголовок — фон }
  FHeaderBg := TCastleRectangleControl.Create(FRoot);
  FHeaderBg.Width := AWidth;
  FHeaderBg.Height := HeaderHeight;
  FHeaderBg.Color := Vector4(0.16, 0.16, 0.18, 1.0);
  FHeaderBg.Anchor(hpLeft, 0);
  FHeaderBg.Anchor(vpTop, 0);
  FRoot.InsertFront(FHeaderBg);

  { Заголовок — текст }
  FHeaderLabel := TMenuLabel.Create(FRoot);
  BindUiText(FHeaderLabel, SENSOR_HEADERS[AKind]);
  FHeaderLabel.FontScale := 1.0;
  FHeaderLabel.Color := Vector4(0.7, 0.7, 0.7, 1);
  FHeaderLabel.Anchor(hpMiddle);
  FHeaderLabel.Anchor(vpMiddle);
  FHeaderBg.InsertFront(FHeaderLabel);

  FNoneButton := TMenuButton.Create(FRoot);
  BindUiText(FNoneButton, 'None');
  FNoneButton.Height := 30;
  FNoneButton.Anchor(vpTop, -(HeaderHeight + 4));
  FNoneButton.OnClick := @ClearSelection;
  FRoot.InsertFront(FNoneButton);
  FSelectionLabel := TMenuLabel.Create(FRoot);
  FSelectionLabel.FontSize := 13;
  FSelectionLabel.Anchor(vpTop, -(HeaderHeight + 40));
  FRoot.InsertFront(FSelectionLabel);

  { Контейнер карточек }
  FCardsHost := TCastleUserInterface.Create(FRoot);
  FCardsHost.Width := AWidth;
  FCardsHost.Height := 0;
  FCardsHost.Anchor(hpLeft, 0);
  FCardsHost.Anchor(vpTop, -(HeaderHeight + 84));
  FRoot.InsertFront(FCardsHost);
end;

destructor TSensorColumn.Destroy;
begin
  FreeAndNil(FCards);
  FreeAndNil(FRoot);
  inherited;
end;

procedure TSensorColumn.SetWidth(const AWidth: Single);
var I: Integer;
begin
  FWidth := AWidth;
  FRoot.Width := AWidth;
  FHeaderBg.Width := AWidth;
  FCardsHost.Width := AWidth;
  FNoneButton.Width := AWidth;
  FSelectionLabel.MaxWidth := AWidth;
  for I := 0 to FCards.Count - 1 do
  begin
    FCards[I].Button.Width := AWidth;
    FCards[I].UpdateVisuals;
  end;
end;

procedure TSensorColumn.Rebuild(AOwner: TComponent);
var
  I: Integer;
  Entry: TGameDeviceEntry;
  Sensor: TDeviceSensor;
  Card: TSensorCard;
  Y: Single;
begin
  FCards.Clear;
  FCardsHost.ClearControls;

  if not Assigned(DeviceService) then Exit;

  Y := 0;
  for I := 0 to DeviceService.Devices.Count - 1 do
  begin
    Entry := DeviceService.Devices[I];
    if (Entry.DeviceInfo.TransportType = ttSim) and
      (not Settings.GetSimulationEnabled or not SameFileName(Entry.DeviceInfo.Address,
        'sim:' + Settings.EffectiveSimulationFitPath)) then Continue;
    Sensor := Entry.FindSensor(FKind);
    if not Assigned(Sensor) then Continue;

    Card := TSensorCard.Create(nil, Sensor, Entry, FKind);
    FCards.Add(Card);
    Card.Button.Width := FWidth;
    Card.Button.Anchor(hpLeft, 0);
    Card.Button.Anchor(vpTop, Y);
    FCardsHost.InsertFront(Card.Button);

    Y := Y - (CardHeight + CardGap);
  end;

  if FCards.Count > 0 then
    FCardsHost.Height := Abs(Y)
  else
    FCardsHost.Height := 0;

  FRoot.Height := HeaderHeight + 84 + FCardsHost.Height;
end;

procedure TSensorColumn.ClearSelection(Sender: TObject);
begin
  if DeviceService <> nil then DeviceService.ClearSensor(FKind);
  UpdateAll;
end;

procedure TSensorColumn.UpdateAll;
var I: Integer; S: String;
begin
  if DeviceService <> nil then
  begin
    SelectMenuButton(FNoneButton, DeviceService.SensorDisabled(FKind));
    S := DeviceService.SelectedSensorName(FKind);
    if (S <> '') and not DeviceService.HasSensor(FKind) then
      S := S + ' / ' + UiText('offline');
    FSelectionLabel.Caption := S;
  end;
  for I := 0 to FCards.Count - 1 do
    FCards[I].UpdateVisuals;
end;

{ ═══════════════════════════════════════════════════════════════════
  TSensorPanel
  ═══════════════════════════════════════════════════════════════════ }

constructor TSensorPanel.Create(AOwner: TComponent);
var K: TSensorKind;
begin
  inherited Create;
  FColumnWidth := 220;
  for K := Low(TSensorKind) to High(TSensorKind) do
    FColumns[K] := nil;
end;

destructor TSensorPanel.Destroy;
var K: TSensorKind;
begin
  for K := Low(TSensorKind) to High(TSensorKind) do
    FreeAndNil(FColumns[K]);
  FreeAndNil(FControlOwner);
  FreeAndNil(FRoot);
  inherited;
end;

procedure TSensorPanel.Build(AParent: TCastleUserInterface);
var
  K: TSensorKind;
begin
  for K := Low(TSensorKind) to High(TSensorKind) do
    FreeAndNil(FColumns[K]);
  FreeAndNil(FControlOwner);
  FreeAndNil(FRoot);
  FParent := AParent;

  FRoot := TCastleUserInterface.Create(nil);
  FRoot.Width := 0;
  FRoot.Height := 400;
  FRoot.Anchor(hpLeft, 0);
  FRoot.Anchor(vpTop, 0);
  AParent.InsertFront(FRoot);

  FControlLabel := TMenuLabel.Create(FRoot);
  FControlLabel.FontSize := 15;
  FControlLabel.Anchor(vpTop);
  FRoot.InsertFront(FControlLabel);
  FControlRow := TMenuFlow.Create(FRoot);
  FControlRow.Spacing := 8;
  FControlRow.Anchor(vpTop, -30);
  FRoot.InsertFront(FControlRow);
  FControlSignature := '#refresh';

  for K := Low(TSensorKind) to High(TSensorKind) do
  begin
    FColumns[K] := TSensorColumn.Create(nil, K, FColumnWidth);
    FColumns[K].Root.Anchor(vpTop, 0);
    FRoot.InsertFront(FColumns[K].Root);
  end;

  RefreshControl;
  Layout;
  Rebuild;
end;

procedure TSensorPanel.Layout;
var
  K: TSensorKind;
  TotalW, Gap, X: Single;
begin
  if (FRoot = nil) or (FParent = nil) then Exit;
  { FullSize controls retain their nominal Width (100 by default).
    RenderRect gives the actual space inside the parent's borders. }
  TotalW := FParent.RenderRect.Width / Max(0.01, FParent.UIScale);
  if TotalW <= 0 then Exit;
  Gap := ColumnGap / Max(0.65, Min(1, FParent.UIScale));
  FColumnWidth := Max(1, (TotalW - Gap * 3) / 4);
  FRoot.Width := TotalW;
  FControlLabel.MaxWidth := TotalW;
  FControlRow.Width := TotalW;
  FControlRow.Arrange;
  X := 0;
  for K := Low(TSensorKind) to High(TSensorKind) do
  begin
    FColumns[K].SetWidth(FColumnWidth);
    FColumns[K].Root.Anchor(vpTop, -(FControlRow.Height + 44));
    FColumns[K].Root.Anchor(hpLeft, X);
    X := X + FColumnWidth + Gap;
  end;
end;

procedure TSensorPanel.Rebuild;
var
  K: TSensorKind;
  MaxH: Single;
begin
  MaxH := 0;
  for K := Low(TSensorKind) to High(TSensorKind) do
    if Assigned(FColumns[K]) then
    begin
      FColumns[K].Rebuild(nil);
      if FColumns[K].Root.Height > MaxH then
        MaxH := FColumns[K].Root.Height;
    end;

  if Assigned(FRoot) then
    FRoot.Height := MaxH + FControlRow.Height + 44;
end;

procedure TSensorPanel.Refresh;
var K: TSensorKind;
begin
  RefreshControl;
  for K := Low(TSensorKind) to High(TSensorKind) do
    if Assigned(FColumns[K]) then
      FColumns[K].UpdateAll;
end;

procedure TSensorPanel.ChooseControl(Sender: TObject);
var I: Integer; E: TGameDeviceEntry;
begin
  if DeviceService = nil then Exit;
  I := TComponent(Sender).Tag;
  if I < 0 then DeviceService.SetControlDevice(nil)
  else if I < DeviceService.Devices.Count then
  begin
    E := DeviceService.Devices[I];
    DeviceService.SetControlDevice(E);
    if E.ConnectionState in [gdcsDisconnected, gdcsError] then DeviceService.ConnectDevice(E);
  end;
  RefreshControl;
end;

procedure TSensorPanel.RefreshControl;
var I: Integer; E: TGameDeviceEntry; Sig, S: String; B: TMenuButton;
begin
  if (DeviceService = nil) or (FControlRow = nil) then Exit;
  Sig := BoolToStr(Settings.GetSimulationEnabled, True);
  for I := 0 to DeviceService.Devices.Count - 1 do
  begin
    E := DeviceService.Devices[I];
    Sig := Sig + ';' + E.DeviceInfo.Address + ':' + BoolToStr(E.IsControllable, True);
  end;
  if Sig <> FControlSignature then
  begin
    FControlSignature := Sig;
    FControlRow.ClearControls;
    FreeAndNil(FControlOwner);
    FControlOwner := TComponent.Create(nil);
    B := TMenuButton.Create(FControlOwner);
    B.Name := 'ControllerNone';
    BindUiText(B, 'None');
    B.FontSize := 14;
    B.Tag := -1;
    B.OnClick := @ChooseControl;
    FControlRow.InsertFront(B);
    for I := 0 to DeviceService.Devices.Count - 1 do
    begin
      E := DeviceService.Devices[I];
      if not E.IsControllable or (E.DeviceInfo.TransportType = ttSim) then Continue;
      B := TMenuButton.Create(FControlOwner);
      B.Name := 'ControllerDevice' + IntToStr(I);
      B.Caption := E.DisplayName;
      B.FontSize := 14;
      B.Tag := I;
      B.OnClick := @ChooseControl;
      FControlRow.InsertFront(B);
    end;
    Layout;
  end;
  S := DeviceService.SelectedControlName;
  if S = '' then
  begin
    if DeviceService.ControlDisabled then S := UiText('None')
    else if DeviceService.HasControlDevice then S := DeviceService.ControlDevice.DisplayName;
  end
  else if not DeviceService.HasControlDevice then S := S + ' / ' + UiText('offline');
  FControlLabel.Caption := UiText('Controllable trainer') + ': ' + S;
  for I := 0 to FControlRow.ControlsCount - 1 do
  begin
    B := TMenuButton(FControlRow.Controls[I]);
    if B.Tag < 0 then SelectMenuButton(B, DeviceService.ControlDisabled)
    else if B.Tag < DeviceService.Devices.Count then
      SelectMenuButton(B, DeviceService.IsControlSelected(DeviceService.Devices[B.Tag]));
    B.Enabled := not Settings.GetSimulationEnabled;
  end;
end;

end.
