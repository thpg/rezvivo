unit GameRideMap;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,fpjson,CastleUIControls,CastleControls,CastleVectors,
  CastleKeysMouse,CastleGLImages,GameGlobeMap,GameMenuTheme,Osm3dGeoMath;
type
  TRideMapMarker=record Geo:TLatLon;Color:TVector4;IsSelf:Boolean end;
  TRideMapMarkers=array of TRideMapMarker;
  TRideMapScene=class(TGlobeMap)
  protected
    procedure RenderOverlay;override;
  public
    Markers:TRideMapMarkers;
    HasTarget:Boolean;
    Target:TLatLon;
  end;
  TCachedRideMap=class(TCastleUserInterface)
  private
    FMap:TRideMapScene;
    FImage:TDrawableImage;
    FNextRender:QWord;
    FDown:TVector2;FPressed,FDragged:Boolean;
    FDragGeo:TLatLon;
    FOnPick:TNotifyEvent;
    FRenderCount:QWord;
    FReady:Boolean;
    function GeoAt(const P:TVector2;out Geo:TLatLon):Boolean;
  public
    Following,PickEnabled:Boolean;
    ZoomLevel:Integer;
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure GLContextOpen;override;
    procedure GLContextClose;override;
    procedure BeforeRender;override;
    procedure Render;override;
    function Press(const Event:TInputPressRelease):Boolean;override;
    function Release(const Event:TInputPressRelease):Boolean;override;
    function Motion(const Event:TInputMotion):Boolean;override;
    procedure Follow(const Geo:TLatLon);
    property Map:TRideMapScene read FMap;
    property OnPick:TNotifyEvent read FOnPick write FOnPick;
    property RenderCount:QWord read FRenderCount;
  end;
  TRideMapPanel=class(TCastleUserInterface)
  private
    FCanvas:TCachedRideMap;
    FHeader,FGrow,FFollow,FZoomIn,FZoomOut,FTeleport,FCancel:TMenuButton;
    FDistance:TCastleLabel;
    FCollapsed,FHasGeography:Boolean;FSize:Integer;
    FOnLayout,FOnTeleport:TNotifyEvent;
    procedure Click(Sender:TObject);
    procedure Pick(Sender:TObject);
    procedure Layout;
  public
    constructor Create(AOwner:TComponent);override;
    procedure Resize;override;
    procedure SetSize(PanelWidth,AvailableHeight:Single);
    procedure SetTravel(FreeTravel,HasGeography:Boolean);
    procedure SetProgress(Distance,Total,Station:Double;Loop:Boolean);
    procedure CancelTarget;
    function Diagnostics:TJSONObject;
    property Canvas:TCachedRideMap read FCanvas;
    property Collapsed:Boolean read FCollapsed;
    property OnLayout:TNotifyEvent read FOnLayout write FOnLayout;
    property OnTeleport:TNotifyEvent read FOnTeleport write FOnTeleport;
  end;
implementation
uses Math,CastleGLUtils,CastleColors,CastleRectangles,CastleImages,UiTranslations;

procedure TRideMapScene.RenderOverlay;
var I:Integer;P:TVector2;A:array[0..24]of TVector2;Radius:Single;
  procedure Disk(const Center:TVector2;R:Single;const C:TVector4);
  var J:Integer;
  begin
    for J:=0 to High(A)do A[J]:=Center+Vector2(Cos(J*Pi/12),Sin(J*Pi/12))*R;
    DrawPrimitive2D(pmTriangleFan,A,C);
  end;
begin
  inherited;
  for I:=0 to High(Markers)do begin
    P:=GeoToScreen(Markers[I].Geo);Radius:=4;if Markers[I].IsSelf then Radius:=6;
    Disk(P,Radius+2,White);Disk(P,Radius+1,Vector4(0.08,0.1,0.12,1));Disk(P,Radius,Markers[I].Color);
    if Markers[I].IsSelf then Disk(P,1.6,White);
  end;
  if HasTarget then begin
    P:=GeoToScreen(Target);Disk(P,8,White);Disk(P,6,Vector4(0.95,0.42,0.15,1));
    DrawPrimitive2D(pmLines,[P+Vector2(-12,0),P+Vector2(12,0),P+Vector2(0,-12),P+Vector2(0,12)],Black);
  end;
end;
constructor TCachedRideMap.Create(AOwner:TComponent);
begin
  inherited;Width:=250;Height:=190;Following:=True;ZoomLevel:=16;
  FMap:=TRideMapScene.Create(Self);FMap.EnableUIScaling:=False;
  FMap.Width:=250;FMap.Height:=190;
end;
destructor TCachedRideMap.Destroy;
begin FreeAndNil(FImage);FreeAndNil(FMap);inherited end;
procedure TCachedRideMap.GLContextOpen;
begin inherited;if FMap<>nil then FMap.GLContextOpen;FNextRender:=0 end;
procedure TCachedRideMap.GLContextClose;
begin FreeAndNil(FImage);if FMap<>nil then FMap.GLContextClose;inherited end;
procedure TCachedRideMap.BeforeRender;
var W,H:Integer;Input:Boolean;NowTick:QWord;
begin
  inherited;
  if(Container=nil)or not Exists or not FReady then Exit;
  NowTick:=GetTickCount64;
  if NowTick<FNextRender then Exit;
  W:=Max(1,Round(RenderRect.Width));H:=Max(1,Round(RenderRect.Height));
  FNextRender:=NowTick+1000; { one map update and render per second, independent of game FPS }
  if(FImage<>nil)and((FImage.Width<>W)or(FImage.Height<>H))then FreeAndNil(FImage);
  if FImage=nil then FImage:=TDrawableImage.Create(W,H,TRGBImage,True);
  FMap.InternalSetContainer(Container);
  FMap.Width:=W;FMap.Height:=H;Input:=False;FMap.Update(1,Input);
  TDrawableImage.BatchingFlush;
  FImage.RenderToImageBegin;
  try Container.RenderControl(FMap,Rectangle(0,0,W,H));finally FImage.RenderToImageEnd end;
  Inc(FRenderCount);
end;
procedure TCachedRideMap.Render;
begin inherited;if FImage<>nil then FImage.Draw(RenderRect) end;
function TCachedRideMap.GeoAt(const P:TVector2;out Geo:TLatLon):Boolean;
var Q:TVector2;
begin
  Result:=False;if(RenderRect.Width<1)or(RenderRect.Height<1)then Exit;
  Q:=P-RenderRect.LeftBottom;
  if(Q.X<0)or(Q.Y<0)or(Q.X>RenderRect.Width)or(Q.Y>RenderRect.Height)then Exit;
  Q:=Vector2(Q.X*FMap.Width/RenderRect.Width,Q.Y*FMap.Height/RenderRect.Height);
  Result:=FMap.TryScreenToGeo(Q,Geo);
end;
function TCachedRideMap.Press(const Event:TInputPressRelease):Boolean;
var P:TLatLon;
begin
  Result:=inherited;
  if Event.IsMouseButton(buttonLeft)and GeoAt(Event.Position,P)then begin
    FDown:=Event.Position;FDragGeo:=P;FPressed:=True;FDragged:=False;Result:=True;
  end;
end;
function TCachedRideMap.Motion(const Event:TInputMotion):Boolean;
var P,C:TLatLon;
begin
  Result:=inherited;if not FPressed then Exit;
  FDragged:=FDragged or((Event.Position-FDown).Length>5*UIScale);
  if FDragged and GeoAt(Event.Position,P)then begin
    C:=FMap.ScreenToGeo(Vector2(FMap.Width*0.5,FMap.Height*0.5));
    C.Lat:=C.Lat+FDragGeo.Lat-P.Lat;C.Lon:=C.Lon+FDragGeo.Lon-P.Lon;
    FMap.CenterAt(C,ZoomLevel);Following:=False;
  end;
  Result:=True;
end;
function TCachedRideMap.Release(const Event:TInputPressRelease):Boolean;
var P:TLatLon;
begin
  Result:=inherited;
  if not Event.IsMouseButton(buttonLeft)or not FPressed then Exit;
  FPressed:=False;Result:=True;
  if PickEnabled and not FDragged and GeoAt(Event.Position,P)then begin
    FMap.Target:=P;FMap.HasTarget:=True;Following:=False;
    if Assigned(FOnPick)then FOnPick(Self);
  end;
end;
procedure TCachedRideMap.Follow(const Geo:TLatLon);
begin FReady:=True;if Following then FMap.CenterAt(Geo,ZoomLevel) end;

constructor TRideMapPanel.Create(AOwner:TComponent);
var Bg:TCastleRectangleControl;
  function Button(const Id,Text:string):TMenuButton;
  begin
    Result:=TMenuButton.Create(Self);Result.Name:=Id;Result.AutoSize:=False;
    Result.AutoIcon:=False;Result.Height:=26;Result.FontSize:=12;
    BindUiText(Result,Text);Result.OnClick:=@Click;InsertFront(Result);
  end;
begin
  inherited;Width:=250;Height:=254;FSize:=1;
  Bg:=TCastleRectangleControl.Create(Self);Bg.FullSize:=True;Bg.Color:=MenuSurface;InsertBack(Bg);
  FCanvas:=TCachedRideMap.Create(Self);FCanvas.Name:='RideMapCanvas';FCanvas.OnPick:=@Pick;InsertFront(FCanvas);
  FHeader:=Button('RideMapToggle','Map');FGrow:=Button('RideMapSize','Size');
  FFollow:=Button('RideMapFollow','Me');FZoomIn:=Button('RideMapZoomIn','+');FZoomOut:=Button('RideMapZoomOut','−');
  FTeleport:=Button('RideMapTeleport','Teleport');FCancel:=Button('RideMapCancel','Cancel');
  FTeleport.Exists:=False;FCancel.Exists:=False;
  FDistance:=TMenuLabel.Create(Self);FDistance.FontSize:=11;FDistance.Color:=MenuText;
  FDistance.Anchor(hpLeft,6);FDistance.Anchor(vpBottom,5);InsertFront(FDistance);
  Layout;
end;
procedure TRideMapPanel.Resize;
begin inherited;if FHeader<>nil then Layout end;
procedure TRideMapPanel.SetSize(PanelWidth,AvailableHeight:Single);
begin
  Width:=PanelWidth;
  if FCollapsed then Height:=30
  else Height:=Min(Max(100,AvailableHeight),150+FSize*70);
  Layout;
end;
procedure TRideMapPanel.Layout;
var W:Single;
begin
  W:=Width;
  FHeader.Width:=Max(36,W-148);FHeader.Anchor(hpLeft,3);FHeader.Anchor(vpTop,-2);
  FGrow.Width:=56;FGrow.Anchor(hpRight,-3);FGrow.Anchor(vpTop,-2);
  FFollow.Width:=28;FFollow.Anchor(hpRight,-61);FFollow.Anchor(vpTop,-2);
  FZoomIn.Width:=26;FZoomIn.Anchor(hpRight,-91);FZoomIn.Anchor(vpTop,-2);
  FZoomOut.Width:=26;FZoomOut.Anchor(hpRight,-119);FZoomOut.Anchor(vpTop,-2);
  FCanvas.Exists:=not FCollapsed;FDistance.Exists:=not FCollapsed;
  FCanvas.Map.PauseTileLoading(FCollapsed or not FHasGeography);
  FFollow.Exists:=not FCollapsed;FZoomIn.Exists:=not FCollapsed;FZoomOut.Exists:=not FCollapsed;
  FCanvas.Width:=Max(1,W-6);FCanvas.Height:=Max(1,Height-53);
  FCanvas.Anchor(hpLeft,3);FCanvas.Anchor(vpTop,-30);
  FTeleport.Width:=Max(70,(W-12)*0.6);FTeleport.Anchor(hpLeft,6);FTeleport.Anchor(vpBottom,25);
  FCancel.Width:=Max(55,(W-12)*0.4-6);FCancel.Anchor(hpRight,-6);FCancel.Anchor(vpBottom,25);
  FTeleport.Exists:=not FCollapsed and FCanvas.PickEnabled and FCanvas.Map.HasTarget;
  FCancel.Exists:=FTeleport.Exists;
end;
procedure TRideMapPanel.Click(Sender:TObject);
var MapCenter:TLatLon;
begin
  if Sender=FHeader then FCollapsed:=not FCollapsed
  else if Sender=FGrow then begin FSize:=(FSize+1)mod 3;FCollapsed:=False end
  else if Sender=FFollow then begin CancelTarget;FCanvas.Following:=True end
  else if(Sender=FZoomIn)or(Sender=FZoomOut)then begin
    if Sender=FZoomIn then Inc(FCanvas.ZoomLevel)else Dec(FCanvas.ZoomLevel);
    FCanvas.ZoomLevel:=EnsureRange(FCanvas.ZoomLevel,12,18);
    MapCenter:=FCanvas.Map.ScreenToGeo(Vector2(FCanvas.Map.Width/2,FCanvas.Map.Height/2));
    FCanvas.Map.CenterAt(MapCenter,FCanvas.ZoomLevel);
  end else if Sender=FCancel then CancelTarget
  else if(Sender=FTeleport)and FCanvas.PickEnabled and FCanvas.Map.HasTarget then begin
    if Assigned(FOnTeleport)then FOnTeleport(Self);CancelTarget;
  end;
  Layout;if Assigned(FOnLayout)then FOnLayout(Self);
end;
procedure TRideMapPanel.Pick(Sender:TObject);
begin Layout end;
procedure TRideMapPanel.CancelTarget;
begin FCanvas.Map.HasTarget:=False;Layout end;
procedure TRideMapPanel.SetTravel(FreeTravel,HasGeography:Boolean);
begin
  FHasGeography:=HasGeography;
  FCanvas.PickEnabled:=FreeTravel and HasGeography;
  if not FCanvas.PickEnabled then FCanvas.Map.HasTarget:=False;
  FCanvas.Map.SetBackgroundEnabled(HasGeography);Layout;
end;
procedure TRideMapPanel.SetProgress(Distance,Total,Station:Double;Loop:Boolean);
var Lap:Integer;
begin
  if Total<=0 then FDistance.Caption:=Format(UiText('%.2f km'),[Distance/1000])
  else begin
    FDistance.Caption:=Format(UiText('%.2f / %.2f km'),[EnsureRange(Station,0.0,Total)/1000,Total/1000]);
    if Loop then begin
      Lap:=1+Floor(Max(0,Distance)/Total);
      if Lap>1 then FDistance.Caption:=FDistance.Caption+' · '+Format(UiText('Lap %d'),[Lap]);
    end;
  end;
end;
function TRideMapPanel.Diagnostics:TJSONObject;
begin
  Result:=TJSONObject.Create(['collapsed',FCollapsed,'renders',Int64(FCanvas.RenderCount),
    'markers',Length(FCanvas.Map.Markers),'zoom',FCanvas.ZoomLevel,'target',FCanvas.Map.HasTarget,
    'pick_enabled',FCanvas.PickEnabled,'width',Width,'height',Height,'distance',FDistance.Caption]);
  Result.Add('map',FCanvas.Map.MapStats);
end;
end.
