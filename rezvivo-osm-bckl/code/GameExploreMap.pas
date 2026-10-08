unit GameExploreMap;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, CastleUIControls, CastleControls, CastleVectors, CastleKeysMouse,
  GameGlobeMap, GameMenuTheme, Osm3dGeoMath, Osm3dGeocode, Osm3dSearchWidget;
type
  TExploreMap = class(TGlobeMap)
  private
    FDown: TVector2;
    FPressed: Boolean;
  protected
    procedure RenderOverlay; override;
  public
    StartPoint: TLatLon;
    HasStart: Boolean;
    OnPick: TNotifyEvent;
    function Press(const Event: TInputPressRelease): Boolean; override;
    function Release(const Event: TInputPressRelease): Boolean; override;
  end;
  TExplorePage = class(TCastleUserInterface)
  private
    FMap: TExploreMap;
    FSearch: TOsm3dSearchWidget;
    FPanel: TCastleRectangleControl;
    FHint, FCoords: TCastleLabel;
    FStart: TMenuButton;
    FOnStart: TNotifyEvent;
    procedure Pick(Sender: TObject);
    procedure Start(Sender: TObject);
    procedure PlacePicked(Sender: TObject; const Hit: TGeoHit);
    function ViewBox(Sender: TObject; out Box: TLatLonBox): Boolean;
    procedure StyleSearch(Sender: TObject);
    procedure Zoom(Sender: TObject);
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    procedure ShowMap;
    procedure HideMap;
    procedure SelectStart(const Geo: TLatLon);
    property Map: TExploreMap read FMap;
    property OnStart: TNotifyEvent read FOnStart write FOnStart;
  end;
implementation
uses Math, CastleGLUtils, CastleColors, AppSettings, UiTranslations;
function TExploreMap.Press(const Event: TInputPressRelease): Boolean;
var P: TLatLon;
begin
  if Event.IsMouseButton(buttonLeft) and TryScreenToGeo(Event.Position,P) then begin
    FDown:=Event.Position;FPressed:=True;
  end;
  Result:=inherited;
end;
function TExploreMap.Release(const Event: TInputPressRelease): Boolean;
var P: TLatLon; Clicked: Boolean;
begin
  Clicked:=FPressed and Event.IsMouseButton(buttonLeft) and
    ((Event.Position-FDown).LengthSqr<25) and TryScreenToGeo(Event.Position,P);
  if Event.IsMouseButton(buttonLeft) then FPressed:=False;
  Result:=inherited;
  if Clicked then begin StartPoint:=P;HasStart:=True;if Assigned(OnPick) then OnPick(Self);Result:=True end;
end;
procedure TExploreMap.RenderOverlay;
var P: TVector2; A: array[0..33] of TVector2; I: Integer; S: Single;
begin
  inherited;if not HasStart then Exit;P:=GeoToScreen(StartPoint);
  S:=RenderRect.Width/Max(1,EffectiveWidth);A[0]:=P;
  for I:=1 to High(A) do A[I]:=P+Vector2(Cos((I-1)*2*Pi/32),Sin((I-1)*2*Pi/32))*(9*S);
  DrawPrimitive2D(pmTriangleFan,A,Vector4(0.1,0.85,0.7,1));
  DrawPrimitive2D(pmLines,[P+Vector2(-15,0)*S,P+Vector2(15,0)*S,
    P+Vector2(0,-15)*S,P+Vector2(0,15)*S],White);
end;
constructor TExplorePage.Create(AOwner: TComponent);
var B: TMenuButton; I: Integer;
begin
  inherited;FullSize:=True;
  FMap:=TExploreMap.Create(Self);FMap.Name:='ExploreStartMap';FMap.FullSize:=True;
  FMap.OnPick:=@Pick;InsertBack(FMap);
  FPanel:=TCastleRectangleControl.Create(Self);FPanel.Color:=MenuSurface;
  FPanel.Width:=352;FPanel.Height:=256;FPanel.Anchor(hpLeft,8);FPanel.Anchor(vpTop,-8);InsertFront(FPanel);
  FHint:=TMenuLabel.Create(Self);FHint.FontSize:=15;FHint.Color:=MenuText;
  BindUiText(FHint,'Choose a starting point on the map. Drag to move; scroll to zoom.');
  FHint.Anchor(hpLeft,12);FHint.Anchor(vpTop,-12);FPanel.InsertFront(FHint);
  FSearch:=TOsm3dSearchWidget.Create(Self);FSearch.AcceptLanguage:=UiLanguage+',en';
  FSearch.OnStyleButton:=@StyleSearch;FSearch.OnPlacePicked:=@PlacePicked;FSearch.OnNeedViewBox:=@ViewBox;
  FSearch.Color:=MenuSurface;FSearch.Anchor(hpLeft,12);FSearch.Anchor(vpTop,-70);StyleMenuFields(FSearch);
  FPanel.InsertFront(FSearch);
  FCoords:=TMenuLabel.Create(Self);FCoords.FontSize:=13;FCoords.Color:=MenuMuted;
  FCoords.Anchor(hpLeft,12);FCoords.Anchor(vpBottom,64);FPanel.InsertFront(FCoords);
  FStart:=TMenuButton.Create(Self);FStart.Name:='ExploreStart';FStart.Style:=mbPrimary;
  BindUiText(FStart,'Start here');FStart.Anchor(hpLeft,12);FStart.Anchor(vpBottom,12);
  FStart.OnClick:=@Start;FStart.Enabled:=False;FPanel.InsertFront(FStart);
  for I:=0 to 1 do begin
    B:=TMenuButton.Create(Self);B.AutoIcon:=False;B.Caption:='+';if I=1 then B.Caption:='-';
    B.Tag:=1-I*2;B.OnClick:=@Zoom;B.Width:=42;B.Height:=40;B.AutoSize:=False;
    B.Anchor(hpRight,-12);B.Anchor(vpTop,-(12+I*46));InsertFront(B);
  end;
end;
procedure TExplorePage.Resize;
begin
  inherited;if FPanel=nil then Exit;
  FPanel.Width:=Min(352,Max(210,EffectiveWidth*0.42));FHint.MaxWidth:=FPanel.Width-24;
  FSearch.Width:=FPanel.Width-24;
end;
procedure TExplorePage.Update(const SecondsPassed:Single;var HandleInput:Boolean);
begin
  inherited;
  FSearch.Anchor(vpTop,-Max(70,FHint.EffectiveHeight+24));
  FPanel.Height:=Max(256,Max(70,FHint.EffectiveHeight+24)+FSearch.EffectiveHeight+112);
end;
procedure TExplorePage.ShowMap;
begin
  FMap.SetActive(True);
  if Settings.ExploreStartSet then SelectStart(TLatLon.Make(Settings.ExploreLat,Settings.ExploreLon))
  else FMap.ShowPlanet;
end;
procedure TExplorePage.HideMap;
begin FMap.SetActive(False) end;
procedure TExplorePage.SelectStart(const Geo: TLatLon);
begin
  FMap.StartPoint:=Geo;FMap.HasStart:=True;FMap.CenterAt(Geo,16);Pick(nil);
end;
procedure TExplorePage.Pick(Sender: TObject);
begin
  if not FMap.HasStart then Exit;
  if Abs(FMap.StartPoint.Lat)>85 then begin FStart.Enabled:=False;Exit end;
  Settings.SetExploreStart(FMap.StartPoint.Lat,FMap.StartPoint.Lon);
  FCoords.Caption:=Format('%.6f, %.6f',[FMap.StartPoint.Lat,FMap.StartPoint.Lon]);
  FStart.Enabled:=True;
end;
procedure TExplorePage.Start(Sender: TObject);
begin if FMap.HasStart and FStart.Enabled and Assigned(FOnStart) then FOnStart(Self) end;
procedure TExplorePage.PlacePicked(Sender: TObject; const Hit: TGeoHit);
begin FMap.CenterAt(Hit.Location,16) end;
function TExplorePage.ViewBox(Sender: TObject; out Box: TLatLonBox): Boolean;
begin Box:=FMap.VisibleBox;Result:=not Box.IsEmpty end;
procedure TExplorePage.StyleSearch(Sender: TObject);
begin if Sender is TCastleButton then StyleMenuButton(TCastleButton(Sender)) end;
procedure TExplorePage.Zoom(Sender: TObject);
begin FMap.ZoomBy(TComponent(Sender).Tag) end;
end.
