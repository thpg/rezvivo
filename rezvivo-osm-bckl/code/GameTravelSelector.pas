unit GameTravelSelector;
{$mode objfpc}{$H+}
interface
uses Classes, CastleControls, CastleUIControls, GameMenuTheme, GameTravel;
type
  TTravelButton = class(TMenuButton)
  public
    Mode: TTravelMode;
    procedure Render; override;
  end;
  TTravelSelector = class(TCastleUserInterface)
  private
    FButtons: array[TTravelMode] of TTravelButton;
    FOnChange: TNotifyEvent;
    procedure ClickMode(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Refresh;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;
implementation
uses Math, CastleVectors, CastleColors, CastleGLUtils, CastleRectangles,
  AppSettings, UiTranslations;
procedure TTravelButton.Render;
var R: TFloatRectangle; C: TCastleColor; X,Y,S: Single;
  procedure Line(A,B,D,E: Single);
  begin DrawPrimitive2D(pmLines,[Vector2(X+A*S,Y+B*S),Vector2(X+D*S,Y+E*S)],C);end;
  procedure Ring(A,B,Radius: Single);
  var P: array[0..24] of TVector2; I: Integer;
  begin
    for I:=0 to High(P) do P[I]:=Vector2(X+(A+Radius*Cos(I*2*Pi/24))*S,Y+(B+Radius*Sin(I*2*Pi/24))*S);
    DrawPrimitive2D(pmLineStrip,P,C);
  end;
begin
  inherited;
  R:=RenderRect;S:=Min(R.Width,R.Height)/32;X:=R.Left+R.Width/2;Y:=R.Bottom+R.Height/2;
  if Enabled then C:=MenuText else C:=Vector4(0.33,0.39,0.42,1);
  case Mode of
    travelWalk: begin Ring(1,10,2.4);Line(0,7,-2,0);Line(-2,0,-8,-10);Line(-2,0,5,-4);Line(5,-4,7,-10);Line(-1,5,6,1);Line(-1,5,-7,1) end;
    travelBicycle,travelMotorcycle: begin
      Ring(-9,-6,5);Ring(9,-6,5);Line(-9,-6,-3,4);Line(-3,4,3,-6);
      Line(3,-6,-9,-6);Line(3,-6,7,5);Line(7,5,9,-6);Line(7,5,4,7);
      Line(-5,4,-1,4);if Mode=travelMotorcycle then begin Line(-8,2,1,2);Line(1,2,4,-2) end;
    end;
    travelBoat: begin Line(-12,-2,12,-2);Line(-12,-2,-7,-9);Line(-7,-9,7,-9);Line(7,-9,12,-2);Line(0,-1,0,12);Line(0,12,9,0);Line(9,0,0,0) end;
    travelCar: begin Line(-12,-6,12,-6);Line(-12,-6,-12,1);Line(-12,1,-7,3);Line(-7,3,-4,9);Line(-4,9,5,9);Line(5,9,9,3);Line(9,3,12,1);Line(12,1,12,-6);Ring(-7,-6,3);Ring(7,-6,3) end;
    travelFlight: begin Line(0,-12,0,13);Line(0,9,-12,-3);Line(-12,-3,-2,1);Line(0,9,12,-3);Line(12,-3,2,1);Line(0,-7,-5,-11);Line(0,-7,5,-11) end;
  end;
end;
constructor TTravelSelector.Create(AOwner: TComponent);
var M: TTravelMode;
begin
  inherited;Width:=280;Height:=40;
  for M:=Low(M) to High(M) do begin
    FButtons[M]:=TTravelButton.Create(Self);FButtons[M].Mode:=M;
    FButtons[M].Name:='Transport_'+TravelIds[M];FButtons[M].Caption:='';FButtons[M].Tag:=Ord(M);
    FButtons[M].AutoIcon:=False;FButtons[M].AutoSize:=False;
    FButtons[M].Width:=42;FButtons[M].Height:=38;FButtons[M].Anchor(hpLeft,Ord(M)*46);
    FButtons[M].OnClick:=@ClickMode;InsertFront(FButtons[M]);
  end;
  Refresh;
end;
procedure TTravelSelector.Refresh;
var M: TTravelMode;
begin
  for M:=Low(M) to High(M) do begin
    FButtons[M].Enabled:=TravelAvailable(M);
    FButtons[M].Tooltip:=UiText(TravelTitles[M]);
    if not TravelAvailable(M) then FButtons[M].Tooltip:=FButtons[M].Tooltip+' — '+UiText('Coming later');
    SelectMenuButton(FButtons[M],Settings.TravelMode=M);
  end;
end;
procedure TTravelSelector.ClickMode(Sender: TObject);
begin
  Settings.TravelMode:=TTravelMode(TComponent(Sender).Tag);Refresh;
  if Assigned(FOnChange) then FOnChange(Self);
end;
end.
