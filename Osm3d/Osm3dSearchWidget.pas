unit Osm3dSearchWidget;

{ overflow/range-проверки выключены намеренно — как и в прочих osm3d-юнитах. }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

{ CGE-виджет поиска места по имени.

  Поток данных:
    поле ввода → (Enter / кнопка «Найти») → TGeocodeThread →
    список подсказок (кнопки) → клик → OnPlacePicked(hit).

  ВАЖНО — соответствие политике Nominatim:
    * запрос уходит ТОЛЬКО по submit, не на каждое нажатие (никакого
      клиентского автокомплита — это запрещено политикой);
    * между запусками выдержан минимальный интервал (>= 1 c);
    * пока поток не завершён, новый запрос не стартует;
    * внизу виджета — обязательная атрибуция OSM.

  Хост подключает виджет в свой Viewport-overlay и подписывается на
  OnPlacePicked, где переводит hit.Location в мировые XZ и двигает камеру. }

interface

uses
  Classes,
  SysUtils,
  CastleControls,
  CastleColors,
  CastleVectors,
  CastleUIControls,
  CastleKeysMouse,
  Osm3dGeoMath,
  Osm3dGeocode;

type
  TPlacePickedEvent = procedure(Sender: TObject; const AHit: TGeoHit) of object;

  { Хост может вернуть текущую видимую гео-рамку, чтобы поднять приоритет
    местных совпадений. Не назначено → глобальный поиск без смещения. }
  TNeedViewBoxEvent = function(Sender: TObject; out ABox: TLatLonBox): Boolean of object;

  TOsm3dSearchWidget = class(TCastleRectangleControl)
  private
    FEdit:        TCastleEdit;
    FSearchBtn:   TCastleButton;
    FStatus:      TCastleLabel;
    FResults:     TCastleVerticalGroup;
    FAttrib:      TCastleLabel;

    FRows:        array of TCastleButton;   { строки подсказок — владеем вручную }
    FThread:      TGeocodeThread;
    FHits:        TGeoHitArray;

    FSinceLaunch: Single;                   { сек с прошлого старта запроса }
    FBusy:        Boolean;

    FAcceptLang:  string;
    FOnPlacePicked: TPlacePickedEvent;
    FOnNeedViewBox: TNeedViewBoxEvent;
    FOnStyleButton: TNotifyEvent;
    procedure SetOnStyleButton(const Value: TNotifyEvent);

    procedure DoSearchClick(Sender: TObject);
    procedure DoRowClick(Sender: TObject);
    procedure ClearRows;
    procedure ShowHits;
    procedure SetStatus(const AMsg: string);
    procedure LaunchSearch;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;

    function Press(const Event: TInputPressRelease): Boolean; override;
    procedure Update(const SecondsPassed: Single;
      var HandleInput: Boolean); override;

    { Программный запуск (например, по горячей клавише хоста). }
    procedure SearchFor(const AText: string);

    { '' → сервер сам решает; иначе напр. 'ru,en'. }
    property AcceptLanguage: string read FAcceptLang write FAcceptLang;
    property OnPlacePicked:  TPlacePickedEvent read FOnPlacePicked write FOnPlacePicked;
    property OnNeedViewBox:  TNeedViewBoxEvent read FOnNeedViewBox write FOnNeedViewBox;
    property OnStyleButton: TNotifyEvent read FOnStyleButton write SetOnStyleButton;
  end;

implementation

uses UiTranslations;


procedure TOsm3dSearchWidget.SetOnStyleButton(const Value: TNotifyEvent);
var I: Integer;
begin
  FOnStyleButton := Value;
  if Assigned(Value) then
  begin
    Value(FSearchBtn);
    for I := 0 to High(FRows) do Value(FRows[I]);
  end;
end;

const
  W_WIDTH        = 360;
  W_PAD          = 8;
  ROW_HEIGHT     = 26;
  EDIT_HEIGHT    = 30;
  MIN_QUERY_LEN  = 2;
  MIN_INTERVAL_S = 1.1;     { >= 1 запрос/с по политике, с запасом }
  MAX_ROW_CHARS  = 56;

function Truncate(const S: string; Max: Integer): string;
var U:UnicodeString;
begin
  U:=UTF8Decode(S);
  if Length(U) <= Max then Result := S
  else Result := UTF8Encode(Copy(U, 1, Max - 1)) + '…';
end;

constructor TOsm3dSearchWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  Width  := W_WIDTH;
  Height := EDIT_HEIGHT + 2 * W_PAD + 18 + 14;   { растёт при показе подсказок }
  Color  := Vector4(0.10, 0.11, 0.13, 0.92);     { полупрозрачная подложка }
  Border.AllSides := 1;
  BorderColor := Vector4(1, 1, 1, 0.12);

  { поле ввода }
  FEdit := TCastleEdit.Create(Self);
  FEdit.Anchor(hpLeft, W_PAD);
  FEdit.Anchor(vpTop, -W_PAD);
  FEdit.Width  := W_WIDTH - 2 * W_PAD - 78;
  FEdit.Height := EDIT_HEIGHT;
  BindUiText(FEdit, 'Place, address…', 'Placeholder');
  FEdit.AutoOnScreenKeyboard := False;
  InsertFront(FEdit);

  { кнопка «Найти» }
  FSearchBtn := TCastleButton.Create(Self);
  FSearchBtn.Anchor(hpRight, -W_PAD);
  FSearchBtn.Anchor(vpTop, -W_PAD);
  BindUiText(FSearchBtn, 'Find');
  FSearchBtn.Height := EDIT_HEIGHT;
  FSearchBtn.AutoSize := False;
  FSearchBtn.FontSize := 16;
  FSearchBtn.Width := 70;
  FSearchBtn.OnClick := @DoSearchClick;
  InsertFront(FSearchBtn);

  { строка статуса }
  FStatus := TCastleLabel.Create(Self);
  FStatus.Anchor(hpLeft, W_PAD);
  FStatus.Anchor(vpTop, -(W_PAD + EDIT_HEIGHT + 4));
  FStatus.Color := Vector4(0.8, 0.82, 0.85, 1);
  FStatus.FontSize := 13;
  FStatus.Caption := '';
  InsertFront(FStatus);

  { контейнер подсказок }
  FResults := TCastleVerticalGroup.Create(Self);
  FResults.Anchor(hpLeft, W_PAD);
  FResults.Anchor(vpTop, -(W_PAD + EDIT_HEIGHT + 22));
  FResults.Spacing := 2;
  InsertFront(FResults);

  { атрибуция — обязательна по лицензии ODbL/политике OSM }
  FAttrib := TCastleLabel.Create(Self);
  FAttrib.Anchor(hpLeft, W_PAD);
  FAttrib.Anchor(vpBottom, 4);
  FAttrib.Color := Vector4(0.6, 0.62, 0.65, 1);
  FAttrib.FontSize := 11;
  BindUiText(FAttrib, '© OpenStreetMap contributors');
  InsertFront(FAttrib);

  FSinceLaunch := MIN_INTERVAL_S;   { первый запрос — без искусственной паузы }
  FBusy := False;
end;

destructor TOsm3dSearchWidget.Destroy;
begin
  if FThread <> nil then
  begin
    FThread.Detach;
    FThread := nil;
  end;
  ClearRows;
  inherited Destroy;
end;

procedure TOsm3dSearchWidget.SetStatus(const AMsg: string);
begin
  FStatus.Caption := AMsg;
end;

procedure TOsm3dSearchWidget.ClearRows;
var
  I: Integer;
begin
  for I := 0 to High(FRows) do
    if FRows[I] <> nil then
    begin
      FResults.RemoveControl(FRows[I]);
      FRows[I].Free;
    end;
  FRows := nil;
end;

procedure TOsm3dSearchWidget.ShowHits;
var
  I,N: Integer;
  B: TCastleButton;
begin
  ClearRows;
  SetLength(FRows, Length(FHits));
  for I := 0 to High(FHits) do
  begin
    B := TCastleButton.Create(nil);   { владеем сами через FRows }
    B.FontSize:=14;
    N:=MAX_ROW_CHARS;
    B.Caption := Truncate(FHits[I].DisplayName, N);
    B.Tag := I;                       { индекс хита }
    B.AutoSize := False;
    B.Width  := W_WIDTH - 2 * W_PAD;
    while (N>4) and (B.Font.TextWidth(B.Caption)>B.Width-20) do begin
      Dec(N);B.Caption:=Truncate(FHits[I].DisplayName,N);
    end;
    B.Height := ROW_HEIGHT;
    B.OnClick := @DoRowClick;
    FResults.InsertFront(B);
    FRows[I] := B;
    if Assigned(FOnStyleButton) then FOnStyleButton(B);
  end;

  { подгоняем высоту виджета под число подсказок }
  Height := W_PAD + EDIT_HEIGHT + 22 +
            Length(FHits) * (ROW_HEIGHT + 2) + 4 + 14 + W_PAD;
end;

procedure TOsm3dSearchWidget.DoRowClick(Sender: TObject);
var
  Idx: Integer;
begin
  if not (Sender is TCastleButton) then Exit;
  Idx := TCastleButton(Sender).Tag;
  if (Idx < 0) or (Idx > High(FHits)) then Exit;
  if Assigned(FOnPlacePicked) then
    FOnPlacePicked(Self, FHits[Idx]);
  { свернуть список после выбора }
  FHits := nil;
  ClearRows;
  SetStatus('');
  Height := EDIT_HEIGHT + 2 * W_PAD + 18 + 14;
end;

procedure TOsm3dSearchWidget.DoSearchClick(Sender: TObject);
begin
  LaunchSearch;
end;

procedure TOsm3dSearchWidget.SearchFor(const AText: string);
begin
  FEdit.Text := AText;
  LaunchSearch;
end;

procedure TOsm3dSearchWidget.LaunchSearch;
var
  Q: TGeoQuery;
  Box: TLatLonBox;
begin
  if FBusy then Exit;                       { пока идёт прошлый запрос — игнор }
  if FSinceLaunch < MIN_INTERVAL_S then      { не чаще 1/с }
  begin
    SetStatus(UiText('Please wait a moment…'));
    Exit;
  end;
  if Length(Trim(FEdit.Text)) < MIN_QUERY_LEN then
  begin
    SetStatus(UiText('Enter at least 2 characters'));
    Exit;
  end;

  Q := TGeoQuery.Make(Trim(FEdit.Text));
  Q.AcceptLang := UiLanguage + ',en';
  if Assigned(FOnNeedViewBox) and FOnNeedViewBox(Self, Box) then
  begin
    Q.HasViewBox := True;
    Q.ViewBox := Box;
  end;

  FThread := TGeocodeThread.Create(Q);
  FBusy := True;
  FSinceLaunch := 0;
  SetStatus(UiText('Searching…'));
end;

procedure TOsm3dSearchWidget.Update(const SecondsPassed: Single;
  var HandleInput: Boolean);
var
  Done, Ok: Boolean;
  Hits: TGeoHitArray;
begin
  inherited Update(SecondsPassed, HandleInput);
  FSinceLaunch := FSinceLaunch + SecondsPassed;

  if FThread = nil then Exit;

  if FThread.Poll(Done, Ok, Hits) then
  begin
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
    FBusy := False;

    if Ok and (Length(Hits) > 0) then
    begin
      FHits := Hits;
      ShowHits;
      SetStatus(Format(UiText('Found: %d'), [Length(Hits)]));
    end
    else
    begin
      FHits := nil;
      ClearRows;
      SetStatus(UiText('Nothing found'));
      Height := EDIT_HEIGHT + 2 * W_PAD + 18 + 14;
    end;
  end;
end;

function TOsm3dSearchWidget.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited Press(Event);
  if Result then Exit;

  { Enter в поле ввода = submit. }
  if Event.IsKey(keyEnter) and FEdit.Focused then
  begin
    LaunchSearch;
    Exit(True);
  end;
end;

end.
