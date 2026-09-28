{ GameViewEvents — вкладка «События» главного меню.

  Встроенная страница (TMenuEmbeddedPage): показывается в правой части
  меню рядом с колонкой плашек, а не полноэкранным вью. Кнопка
  ← Назад возвращает на вкладку «Маршруты».

  ⚠ ВАЖНО: этот экран НАМЕРЕННО не делает сетевых вызовов. После
  ревизии исходников VeloSite (chi-роуты в internal/server/server.go)
  подтверждено: эндпоинты `/events`, `/events/{slug}`,
  `/events/{slug}/register` и `/me/events` ОТДАЮТ HTML-страницы для
  браузера (httpx.Renderer.HTML), а JSON-API для событий не существует.

  Что у нас есть из API в эту сторону:
    POST /api/v1/rides → metadata.event_id
        — игра может пометить заезд id'ом события (TVeloSiteRideUpload.
        EventId), и сервер свяжет его с гонкой. Но для этого id
        приходится получать вне игры.

  Чтобы достроить экран событий внутри игры, бэкенду нужно добавить:
    1. GET  /api/v1/events?status=upcoming
    2. POST /api/v1/events/{id}/register
    3. GET  /api/v1/events/{id}
    4. (опц.) WS- или relay-канал «live event».

  Пока — страница показывает информативное сообщение и кнопку
  возврата на вкладку «Маршруты». }
unit GameViewEvents;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses GameMenuTheme,
  Classes, SysUtils,
  CastleComponentSerialize, CastleUIControls, CastleControls,
  CastleVectors,
  VeloSiteAPI,
  GameMenuTile;

type
  TEventsPage = class(TMenuEmbeddedPage)
  private
    FDesign:     TCastleDesign;
    FLabelTitle: TCastleLabel;
    FLabelHint:  TCastleLabel;
    FButtonBack: TCastleButton;
    FStatusLabel: TCastleLabel;
    FListHost:    TCastleUserInterface;

    procedure ClickBack(Sender: TObject);
    procedure OpenWebsite(Sender: TObject);
    procedure UpdateStatus;
  public
    constructor Create(AOwner: TComponent); override;
    procedure PageShown; override;
  end;

var
  ViewEvents: TEventsPage;

implementation

uses UiTranslations,
  GameViewMenu, GameLocalization, CastleOpenDocument;

constructor TEventsPage.Create(AOwner: TComponent);
var Website: TMenuButton;
begin
  inherited;
  FullSize := True;

  { Дизайн бывшего полноэкранного вью встраиваем целиком. }
  FDesign := TCastleDesign.Create(Self);
  FDesign.FullSize := True;
  FDesign.Url := 'castle-data:/gameviewevents.castle-user-interface';
  LocalizeDesignedUi(FDesign);
  InsertFront(FDesign);

  FLabelTitle := FDesign.DesignedComponent('LabelTitle') as TCastleLabel;
  FLabelHint  := FDesign.DesignedComponent('LabelHint') as TCastleLabel;
  FLabelHint.Exists := False;
  FButtonBack := FDesign.DesignedComponent('ButtonBack') as TCastleButton;
  if FLabelTitle <> nil then
    FLabelTitle.Exists := False;
  if FButtonBack <> nil then
    FButtonBack.Exists := True;
  BindUiText(FButtonBack, 'Back to routes');
  FButtonBack.FontSize := 16;
  FButtonBack.Anchor(hpLeft, 20);
  FButtonBack.Anchor(vpTop, -120);
  FButtonBack.OnClick := @ClickBack;

  { Хост списка и статус-строка — кодовый UI поверх дизайна. FreeAtStop
    у страницы нет, поэтому создаём один раз с owner Self. }
  FListHost := TCastleUserInterface.Create(Self);
  FListHost.Width := 1100;
  FListHost.Height := 500;
  FListHost.Anchor(hpMiddle);
  FListHost.Anchor(vpMiddle);
  InsertFront(FListHost);

  FStatusLabel := TMenuLabel.Create(Self);
  FStatusLabel.FontScale := 1.0;
  FStatusLabel.Color := Vector4(0.85, 0.85, 0.9, 1);
  FStatusLabel.Anchor(hpLeft, 20);
  FStatusLabel.MaxWidth := 900;
  FStatusLabel.Anchor(vpTop, -16);
  InsertFront(FStatusLabel);
  Website := TMenuButton.Create(Self);
  Website.Name := 'OpenEventsWebsite';
  BindUiText(Website, 'Open events website');
  Website.FontSize := 20;
  Website.Anchor(hpLeft, 20); Website.Anchor(vpTop, -76);
  Website.OnClick := @OpenWebsite; InsertFront(Website);
end;

procedure TEventsPage.PageShown;
begin
  { Может вызываться повторно (вкладку свернули и открыли снова) —
    как и бывший Start, просто обновляем подписи и статус. }
  if FLabelTitle <> nil then
    FLabelTitle.Exists := False;
  if FButtonBack <> nil then
    FButtonBack.Exists := True;
  UpdateStatus;
end;

procedure TEventsPage.UpdateStatus;
begin
  BindUiText(FStatusLabel, 'Event schedule and registration are available on the website.');
end;

procedure TEventsPage.OpenWebsite(Sender: TObject);
begin
  OpenURL(ExcludeTrailingPathDelimiter(VeloSite.BaseUrl) + '/events');
end;

procedure TEventsPage.ClickBack(Sender: TObject);
begin
  ViewMenu.ShowRoutesPage;
end;

end.
