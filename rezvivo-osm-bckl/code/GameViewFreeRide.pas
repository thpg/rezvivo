{ GameViewFreeRide — экран «Свободная езда».
  Содержит кнопку запуска игрового мира (TViewPlay) и возврат в меню. }
unit GameViewFreeRide;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses GameMenuTheme,
  Classes, SysUtils,
  CastleComponentSerialize, CastleUIControls, CastleControls;

type
  TViewFreeRide = class(TCastleView)
  published
    LabelTitle: TCastleLabel;
    LabelHint:  TCastleLabel;
    ButtonBack: TCastleButton;
    ButtonStart: TCastleButton;
  private
    procedure ClickBack(Sender: TObject);
    procedure ClickStart(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Start; override;
  end;

var
  ViewFreeRide: TViewFreeRide;

implementation

uses UiTranslations,
  GameViewMenu, GameViewPlay;

constructor TViewFreeRide.Create(AOwner: TComponent);
begin
  inherited;
  DesignUrl := 'castle-data:/gameviewfreeride.castle-user-interface';
end;

procedure TViewFreeRide.Start;
begin
  inherited;
  LocalizeDesignedUi(Self);
  if Assigned(ButtonBack)  then ButtonBack.OnClick  := @ClickBack;
  if Assigned(ButtonStart) then ButtonStart.OnClick := @ClickStart;
end;

procedure TViewFreeRide.ClickBack(Sender: TObject);
begin
  Container.View := ViewMenu;
end;

procedure TViewFreeRide.ClickStart(Sender: TObject);
begin
  { Запускаем стриминг по FIT, выбранному в меню на странице «Маршруты»
    (или dev sim-FIT, если ничего не выбрано). Пустая строка = дефолтный
    мир без стриминга. }
  ViewPlay.CurrentFitPath := ViewMenu.SelectedFitPath;
  Container.View := ViewPlay;
end;

end.
