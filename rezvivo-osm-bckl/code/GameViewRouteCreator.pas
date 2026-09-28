unit GameViewRouteCreator;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses GameMenuTheme, Classes, SysUtils, fpjson, CastleUIControls, CastleControls, CastleVectors,
  CastleKeysMouse, GameMenuTile, GameRouteMap, GameRoutePlanner,
  GameRoutePlannerJobs, Osm3dGeoMath, Osm3dGeocode, Osm3dSearchWidget;
type
  TRouteCreatorPage = class;
  TPlannerMap = class(TRouteMap)
  private
    FPage:TRouteCreatorPage;
    FMarkerDrag:Integer;
    FPressed:Boolean;
    FDown:TVector2;
    function HitMarker(const P:TVector2):Integer;
    function Inside(const P:TVector2):Boolean;
  protected
    procedure RenderOverlay;override;
  public
    constructor Create(AOwner:TComponent);override;
    procedure CancelDrag;
    function Press(const Event:TInputPressRelease):Boolean;override;
    function Motion(const Event:TInputMotion):Boolean;override;
    function Release(const Event:TInputPressRelease):Boolean;override;
  end;
  TRouteCreatorPage = class(TMenuEmbeddedPage)
  published
    Map:TPlannerMap;
    Search:TOsm3dSearchWidget;
    TitleEdit:TCastleEdit;
    LoopCheck:TCastleCheckbox;
    Status:TCastleLabel;
    SaveButton:TCastleButton;
  private
    FGraph:TPlannerGraph;
    FLoadTask,FRouteTask:TPlannerTask;
    FStops,FPath:TPlannerPoints;
    FSnapped:array of Boolean;
    FSelected,FRevision,FReadyRevision:Integer;
    FActive,FNeedLoad,FNeedRoute:Boolean;
    FLoadDelay,FRouteDelay:Single;
    FCacheRoot,FEndpoints:string;
    FDetails:TCastleLabel;
    FDelete,FClear,FUndo,FRetry,FSaveOnly:TCastleButton;
    FUndoStops:TPlannerPoints;
    FUndoLoop,FCanUndo,FLoadingDraft:Boolean;
    FDraftDelay:Single;
    procedure RememberUndo;
    procedure ClickUndo(Sender:TObject);
    procedure SaveDraft;
    procedure LoadDraft;
    procedure DraftChanged(Sender:TObject);
    procedure Layout;
    procedure StyleSearchButton(Sender: TObject);
    procedure MapChanged(Sender:TObject);
    procedure PlacePicked(Sender:TObject;const Hit:TGeoHit);
    function NeedViewBox(Sender:TObject;out Box:TLatLonBox):Boolean;
    procedure ClickBack(Sender:TObject);
    procedure ClickDelete(Sender:TObject);
    procedure ClickClear(Sender:TObject);
    procedure ClickSave(Sender:TObject);
    procedure ClickRetry(Sender:TObject);
    procedure ClickZoom(Sender:TObject);
    procedure ChangeLoop(Sender:TObject);
    procedure EditPoint(Index:Integer;const P:TLatLon;FinalMove:Boolean);
    procedure InvalidateRoute;
    procedure DisplayPath;
    procedure UpdateDetails;
    procedure StartLoad;
    procedure StartRoute;
    function AllSnapped:Boolean;
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure PageShown;override;
    procedure PageHidden;override;
    function MapDiagnostics:TJSONObject;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
  end;
implementation
uses UiTranslations, Math, CastleRectangles, CastleColors, CastleGLUtils, CastleFonts,
  Osm3dStudioSettings, GameViewMenu, GameViewMapEditor, GameUserData, GameRouteLibraryData;

constructor TPlannerMap.Create(AOwner:TComponent);
begin inherited;FMarkerDrag:=-1;end;
function TPlannerMap.Inside(const P:TVector2):Boolean;
var Geo:TLatLon;
begin Result:=TryScreenToGeo(P,Geo);end;
function TPlannerMap.HitMarker(const P:TVector2):Integer;
var I:Integer;Q:TVector2;D,Best:Single;
begin
  Result:=-1;Best:=Sqr(16*RenderRect.Width/Max(1,EffectiveWidth));
  for I:=High(FPage.FStops) downto 0 do begin
    Q:=GeoToScreen(FPage.FStops[I]);D:=Sqr(P.X-Q.X)+Sqr(P.Y-Q.Y);
    if D<Best then begin Best:=D;Result:=I;end;
  end;
end;
procedure TPlannerMap.CancelDrag;
begin FMarkerDrag:=-1;FPressed:=False;SetActive(False);end;
function TPlannerMap.Press(const Event:TInputPressRelease):Boolean;
var I:Integer;
begin
  if Inside(Event.Position) and Event.IsMouseButton(buttonLeft) then begin
    I:=HitMarker(Event.Position);
    if I>=0 then begin
      FPage.RememberUndo;FMarkerDrag:=I;FPage.FSelected:=I;FPage.UpdateDetails;Exit(True);
    end;
    FDown:=Event.Position;FPressed:=True;
  end;
  Result:=inherited;
end;
function TPlannerMap.Motion(const Event:TInputMotion):Boolean;
begin
  if FMarkerDrag>=0 then begin
    if Inside(Event.Position) then FPage.EditPoint(FMarkerDrag,ScreenToGeo(Event.Position),False);
    Exit(True);
  end;
  Result:=inherited;
end;
function TPlannerMap.Release(const Event:TInputPressRelease):Boolean;
begin
  if Event.IsMouseButton(buttonLeft) then begin
    if FMarkerDrag>=0 then begin
      if Inside(Event.Position) then FPage.EditPoint(FMarkerDrag,ScreenToGeo(Event.Position),True);
      FMarkerDrag:=-1;FPage.FRouteDelay:=0;Exit(True);
    end;
    Result:=inherited;
    if FPressed and Inside(Event.Position) and
      (Sqr(Event.Position.X-FDown.X)+Sqr(Event.Position.Y-FDown.Y)<25) then
      FPage.EditPoint(-1,ScreenToGeo(Event.Position),True);
    FPressed:=False;Exit;
  end;
  Result:=inherited;
end;
procedure TPlannerMap.RenderOverlay;
var I:Integer;P:TVector2;R,Scale:Single;C:TCastleColor;S:string;
    Fan:array[0..33]of TVector2;Font:TCastleAbstractFont;
  procedure Disc(Radius:Single;const Color:TCastleColor);
  var J:Integer;
  begin
    Fan[0]:=P;
    for J:=1 to High(Fan) do Fan[J]:=Vector2(P.X+Radius*Cos((J-1)*2*Pi/32),P.Y+Radius*Sin((J-1)*2*Pi/32));
    DrawPrimitive2D(pmTriangleFan,Fan,Color);
  end;
begin
  if FPage=nil then Exit;Scale:=RenderRect.Width/Max(1,EffectiveWidth);Font:=UIFont;
  for I:=0 to High(FPage.FStops) do begin
    P:=GeoToScreen(FPage.FStops[I]);if not Inside(P) then Continue;
    R:=12*Scale;C:=Vector4(0.03,0.38,0.8,1);
    if I=0 then C:=Vector4(0.06,0.55,0.24,1);
    if not FPage.FSnapped[I] then C:=Vector4(0.8,0.2,0.1,1);
    if I=FPage.FSelected then Disc(R+4*Scale,Vector4(1,0.72,0.05,1))
    else Disc(R+2*Scale,White);
    Disc(R,C);S:=IntToStr(I+1);
    if Font<>nil then Font.Print(P.X-Font.TextWidth(S)/2,P.Y-Font.TextHeight(S)/2,White,S);
  end;
end;

constructor TRouteCreatorPage.Create(AOwner:TComponent);
var BG,Credit:TCastleRectangleControl;Col:TCastleVerticalGroup;Row:TCastleHorizontalGroup;
    L:TCastleLabel;B:TCastleButton;Settings:TStudioSettings;
  function ButtonText(const Caption:string;Click:TNotifyEvent):TCastleButton;
  begin Result:=TMenuButton.Create(Self);BindUiText(Result, Caption);Result.FontSize:=15;
    Result.OnClick:=Click;Row.InsertFront(Result);end;
  procedure LabelText(const Caption:string);
  begin L:=TMenuLabel.Create(Self);BindUiText(L, Caption);L.FontSize:=15;
    L.Color:=Vector4(0.88,0.92,0.96,1);L.MaxWidth:=350;Col.InsertFront(L);end;
begin
  inherited;FullSize:=True;FSelected:=-1;FReadyRevision:=-1;
  Settings:=TStudioSettings.Defaults;FCacheRoot:=Settings.CacheRoot;FEndpoints:=Settings.OverpassEndpoints;
  BG:=TCastleRectangleControl.Create(Self);BG.FullSize:=True;BG.Color:=MenuBackground;InsertBack(BG);
  Row:=TCastleHorizontalGroup.Create(Self);Row.Spacing:=18;Row.Anchor(hpLeft,8);Row.Anchor(vpTop,-8);InsertFront(Row);
  B:=ButtonText(UiText('← Routes'),@ClickBack);
  L:=TMenuLabel.Create(Self);BindUiText(L, 'Create route');L.FontSize:=24;L.Color:=White;Row.InsertFront(L);
  Map:=TPlannerMap.Create(Self);Map.FPage:=Self;Map.Anchor(hpLeft,380);Map.Anchor(vpTop,-58);
  Map.OnChanged:=@MapChanged;Map.CenterAt(TLatLon.Make(55.75,37.62),0);InsertFront(Map);
  Col:=TCastleVerticalGroup.Create(Self);Col.Spacing:=16;Col.Anchor(hpLeft,8);Col.Anchor(vpTop,-58);InsertFront(Col);
  Search:=TOsm3dSearchWidget.Create(Self);Search.AcceptLanguage:=UiLanguage + ',en';
  Search.OnStyleButton := @StyleSearchButton;
  Search.OnPlacePicked:=@PlacePicked;Search.OnNeedViewBox:=@NeedViewBox;Col.InsertFront(Search);
  Search.Color:=MenuSurface;StyleMenuFields(Search);
  LabelText(UiText('Route name'));
  TitleEdit:=TMenuEdit.Create(Self);TitleEdit.Name:='RouteTitleInput';TitleEdit.Width:=350;TitleEdit.Text:=UiText('New route');TitleEdit.OnChange:=@DraftChanged;Col.InsertFront(TitleEdit);
  LoopCheck:=TCastleCheckbox.Create(Self);BindUiText(LoopCheck, 'Loop route');LoopCheck.FontSize:=16;
  LoopCheck.TextColor:=White;LoopCheck.CheckboxColor:=Vector4(0.8,0.85,0.9,1);LoopCheck.OnChange:=@ChangeLoop;Col.InsertFront(LoopCheck);
  LabelText(UiText('Click the map to add a point.')+LineEnding+
    UiText('Drag a point to change the route.')+LineEnding+
    UiText('Drag the globe to rotate it.')+LineEnding+UiText('Use the mouse wheel to zoom.'));
  FDetails:=TMenuLabel.Create(Self);FDetails.FontSize:=16;FDetails.Color:=White;FDetails.MaxWidth:=350;Col.InsertFront(FDetails);
  Row:=TCastleHorizontalGroup.Create(Self);Row.Spacing:=8;Col.InsertFront(Row);
  FDelete:=ButtonText(UiText('Delete point'),@ClickDelete);FClear:=ButtonText(UiText('Clear'),@ClickClear);
  Row:=TCastleHorizontalGroup.Create(Self);Row.Spacing:=8;Col.InsertFront(Row);
  FUndo:=ButtonText(UiText('Undo'),@ClickUndo);FUndo.Name:='UndoRoutePoint';FUndo.Enabled:=False;
  FRetry:=ButtonText(UiText('Retry loading roads'),@ClickRetry);FRetry.Exists:=False;
  Row:=TCastleHorizontalGroup.Create(Self);Col.InsertFront(Row);
  SaveButton:=ButtonText(UiText('Save and ride'),@ClickSave);SaveButton.Name:='SaveAndRideRoute';SaveButton.Enabled:=False;SaveButton.Tag:=1;
  TMenuButton(SaveButton).Style:=mbPrimary;TMenuButton(SaveButton).AutoIcon:=False;
  FSaveOnly:=ButtonText(UiText('Save only'),@ClickSave);FSaveOnly.Name:='SaveRouteOnly';FSaveOnly.Enabled:=False;
  Row:=TCastleHorizontalGroup.Create(Self);Row.Spacing:=4;Row.Anchor(hpRight,-16);Row.Anchor(vpTop,-66);InsertFront(Row);
  B:=ButtonText(UiText('Globe'),@ClickZoom);B.Tag:=0;
  B:=ButtonText('−',@ClickZoom);B.Tag:=-1;B:=ButtonText('+',@ClickZoom);B.Tag:=1;
  L:=TMenuLabel.Create(Self);BindUiText(L, '© OpenStreetMap contributors · Natural Earth · Copernicus DEM');L.FontSize:=11;
  Credit:=TCastleRectangleControl.Create(Self);Credit.Width:=450;Credit.Height:=22;
  Credit.Color:=Vector4(0.013,0.025,0.045,0.82);Credit.Anchor(hpRight,-8);Credit.Anchor(vpBottom,42);InsertFront(Credit);
  L.Color:=Vector4(0.9,0.94,0.96,1);L.Anchor(hpRight,-4);L.Anchor(vpBottom,4);Credit.InsertFront(L);
  Status:=TMenuLabel.Create(Self);Status.FontSize:=15;Status.Color:=Vector4(0.86,0.92,1,1);
  Status.Anchor(hpLeft,8);Status.Anchor(vpBottom,8);InsertFront(Status);
  BindUiText(Status, 'Find a place and add points on roads');LoadDraft;UpdateDetails;Layout;
end;
destructor TRouteCreatorPage.Destroy;
begin
  DetachPlannerTask(FLoadTask);DetachPlannerTask(FRouteTask);
  if FGraph<>nil then FGraph.Release;inherited;
end;
procedure TRouteCreatorPage.StyleSearchButton(Sender: TObject);
var B: TCastleButton;
begin
  B := Sender as TCastleButton;
  StyleMenuButton(B);
  B.PaddingHorizontal := 6;
  B.PaddingVertical := 4;
  B.FontSize := 14;
end;

procedure TRouteCreatorPage.Layout;
begin Map.Width:=Max(100,EffectiveWidth-388);Map.Height:=Max(100,EffectiveHeight-100);
  Status.MaxWidth:=Max(200,EffectiveWidth-16);end;
procedure TRouteCreatorPage.PageShown;
begin inherited;FActive:=True;Map.SetActive(True);FNeedLoad:=True;FLoadDelay:=0.3;
  if Length(FStops)>1 then FNeedRoute:=True;end;
procedure TRouteCreatorPage.PageHidden;
begin inherited;SaveDraft;FActive:=False;Map.SetActive(False);Map.CancelDrag;DetachPlannerTask(FLoadTask);DetachPlannerTask(FRouteTask);end;
function TRouteCreatorPage.MapDiagnostics:TJSONObject;
var I:Integer;A:TJSONArray;
begin
  Result:=TJSONObject.Create(['points',Length(FStops),'path_points',Length(FPath),'save_enabled',SaveButton.Enabled,
    'loading',FLoadTask<>nil,'routing',FRouteTask<>nil,'loop',LoopCheck.Checked,'status',Status.Caption]);
  if Length(FPath)>1 then Result.Add('path_closed',
    (Abs(FPath[0].Lat-FPath[High(FPath)].Lat)<1E-8)and(Abs(FPath[0].Lon-FPath[High(FPath)].Lon)<1E-8));
  A:=TJSONArray.Create;Result.Add('stops',A);
  for I:=0 to High(FStops)do A.Add(TJSONObject.Create(['lat',FStops[I].Lat,'lon',FStops[I].Lon,'snapped',FSnapped[I]]));
end;
procedure TRouteCreatorPage.MapChanged(Sender:TObject);
begin FNeedLoad:=True;FLoadDelay:=0.3;end;
procedure TRouteCreatorPage.PlacePicked(Sender:TObject;const Hit:TGeoHit);
begin DetachPlannerTask(FLoadTask);Map.CenterAt(Hit.Location,15);MapChanged(nil);end;
function TRouteCreatorPage.NeedViewBox(Sender:TObject;out Box:TLatLonBox):Boolean;
begin Box:=Map.VisibleBox;Result:=not Box.IsEmpty;end;
procedure TRouteCreatorPage.ClickBack(Sender:TObject);
begin ViewMenu.ShowRoutesPage;end;
procedure TRouteCreatorPage.ClickZoom(Sender:TObject);
begin if TComponent(Sender).Tag=0 then Map.ShowPlanet else Map.ZoomBy(TComponent(Sender).Tag);end;
procedure TRouteCreatorPage.ClickRetry(Sender:TObject);
begin DetachPlannerTask(FLoadTask);FNeedLoad:=True;FLoadDelay:=0;end;
procedure TRouteCreatorPage.ChangeLoop(Sender:TObject);
begin if FLoadingDraft then Exit;RememberUndo;FUndoLoop:=not LoopCheck.Checked;InvalidateRoute;end;
procedure TRouteCreatorPage.ClickClear(Sender:TObject);
begin RememberUndo;FStops:=nil;FSnapped:=nil;FSelected:=-1;InvalidateRoute;end;
procedure TRouteCreatorPage.ClickDelete(Sender:TObject);
var I:Integer;
begin
  if (FSelected<0)or(FSelected>=Length(FStops)) then Exit;
  RememberUndo;
  for I:=FSelected to High(FStops)-1 do begin FStops[I]:=FStops[I+1];FSnapped[I]:=FSnapped[I+1];end;
  SetLength(FStops,Length(FStops)-1);SetLength(FSnapped,Length(FStops));
  FSelected:=Min(FSelected,High(FStops));InvalidateRoute;
end;
procedure TRouteCreatorPage.EditPoint(Index:Integer;const P:TLatLon;FinalMove:Boolean);
var S:TPlannerSnap;OK:Boolean;
begin
  OK:=(FGraph<>nil)and FGraph.Snap(P,S);
  if Index<0 then begin RememberUndo;Index:=Length(FStops);SetLength(FStops,Index+1);SetLength(FSnapped,Index+1);end;
  FSelected:=Index;FSnapped[Index]:=OK;
  if OK then FStops[Index]:=S.Position else FStops[Index]:=P;
  InvalidateRoute;
  if FinalMove then FRouteDelay:=0;
  if not OK then begin
    FNeedLoad:=True;FLoadDelay:=0.2;
    BindUiText(Status, 'Point is not snapped. Checking nearby roads…');
  end;
end;
procedure TRouteCreatorPage.InvalidateRoute;
begin
  FDraftDelay:=1;
  Inc(FRevision);FReadyRevision:=-1;FNeedRoute:=Length(FStops)>1;FRouteDelay:=0.15;
  if FRouteTask<>nil then FRouteTask.Terminate;
  FPath:=nil;DisplayPath;SaveButton.Enabled:=False;FSaveOnly.Enabled:=False;UpdateDetails;
  if Length(FStops)<2 then BindUiText(Status, 'Add at least two points on roads')
  else BindUiText(Status, 'Recalculating route…');
end;
function TRouteCreatorPage.AllSnapped:Boolean;
var I:Integer;
begin Result:=True;for I:=0 to High(FSnapped) do if not FSnapped[I] then Exit(False);end;
procedure TRouteCreatorPage.UpdateDetails;
begin
  FDetails.Caption:=UiText('Points: ')+IntToStr(Length(FStops));
  if FSelected>=0 then FDetails.Caption:=FDetails.Caption+UiText('   Selected: ')+IntToStr(FSelected+1);
  if Length(FPath)>1 then FDetails.Caption:=FDetails.Caption+LineEnding+Format(UiText('Distance: %.2f km'),[PlannerLength(FPath)/1000]);
  FDelete.Exists:=FSelected>=0;FClear.Exists:=Length(FStops)>0;
  FUndo.Enabled:=FCanUndo;
end;
procedure TRouteCreatorPage.DisplayPath;
var A,Segments,Line:TJSONArray;O:TJSONObject;I:Integer;
begin
  A:=TJSONArray.Create;
  try
    if Length(FPath)>1 then begin
      O:=TJSONObject.Create;A.Add(O);O.Add('id',1);Segments:=TJSONArray.Create;O.Add('map_path',Segments);
      Line:=TJSONArray.Create;Segments.Add(Line);
      for I:=0 to High(FPath) do Line.Add(TJSONArray.Create([FPath[I].Lon,FPath[I].Lat]));
    end;
    Map.SetRoutes(A);
  finally A.Free;end;
end;
procedure TRouteCreatorPage.StartLoad;
var Box:TLatLonBox;I:Integer;
begin
  FNeedLoad:=False;Box:=Map.VisibleBox;
  if Box.IsEmpty or (Map.Zoom<12) then begin
    BindUiText(Status, 'Zoom in to load roads');Exit;
  end;
  for I:=0 to High(FStops) do Box:=Box.Include(FStops[I]);Box:=Box.ExpandMeters(800);
  if (FGraph<>nil)and(Box.MinLat>=FGraph.Coverage.MinLat)and(Box.MaxLat<=FGraph.Coverage.MaxLat)and
    (Box.MinLon>=FGraph.Coverage.MinLon)and(Box.MaxLon<=FGraph.Coverage.MaxLon) then begin
    if not AllSnapped then BindUiText(Status, 'No usable road within 100 m of the red point. Drag it closer');Exit;
  end;
  FLoadTask:=TPlannerTask.CreateLoad(Box,FCacheRoot,FEndpoints);FLoadTask.Start;
end;
procedure TRouteCreatorPage.StartRoute;
begin
  if (FGraph=nil)or(FLoadTask<>nil)or(FNeedLoad)then Exit;
  FNeedRoute:=False;
  if not AllSnapped then begin
    BindUiText(Status, 'Drag red points closer to a road');Exit;
  end;
  FRouteTask:=TPlannerTask.CreateRoute(FGraph,FStops,LoopCheck.Checked,FRevision);FRouteTask.Start;
  BindUiText(Status, 'Routing along roads…');
end;
procedure TRouteCreatorPage.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var G:TPlannerGraph;I:Integer;S:TPlannerSnap;
begin
  inherited;
  if FDraftDelay>0 then begin
    FDraftDelay:=Max(0,FDraftDelay-SecondsPassed);if FDraftDelay=0 then SaveDraft;
  end;
  FRetry.Exists:=(FLoadTask=nil)and(FRouteTask=nil)and not FNeedLoad and not FNeedRoute and
    (FReadyRevision<>FRevision)and(Length(FStops)>0);if not FActive then Exit;Layout;
  if FLoadTask<>nil then begin
    if FLoadTask.Done then begin
      G:=FLoadTask.TakeGraph;
      if G<>nil then begin
        if FGraph<>nil then FGraph.Release;FGraph:=G;
        for I:=0 to High(FStops) do begin
          FSnapped[I]:=FGraph.Snap(FStops[I],S);if FSnapped[I]then FStops[I]:=S.Position;
        end;
        InvalidateRoute;
        if Length(FStops)=0 then BindUiText(Status, 'Roads loaded. Add route points');
      end else Status.Caption:=FLoadTask.ErrorText;
      FreeAndNil(FLoadTask);
    end else Status.Caption:=FLoadTask.Progress;
  end;
  if FRouteTask<>nil then if FRouteTask.Done then begin
    if FRouteTask.Revision=FRevision then begin
      FPath:=Copy(FRouteTask.Points);DisplayPath;UpdateDetails;
      if (FRouteTask.ErrorText='')and(Length(FPath)>1) then begin
        FReadyRevision:=FRevision;SaveButton.Enabled:=True;FSaveOnly.Enabled:=True;
        BindUiText(Status, 'Route ready. Move points or save it');
      end else Status.Caption:=FRouteTask.ErrorText;
    end;
    FreeAndNil(FRouteTask);
  end;
  FLoadDelay:=Max(0,FLoadDelay-SecondsPassed);FRouteDelay:=Max(0,FRouteDelay-SecondsPassed);
  if FNeedLoad and(FLoadTask=nil)and(FLoadDelay<=0)then StartLoad;
  if FNeedRoute and(FRouteTask=nil)and(FRouteDelay<=0)then StartRoute;
end;
procedure TRouteCreatorPage.ClickSave(Sender:TObject);
var Title,Base,FileName:string;I,N:Integer;
begin
  if(FReadyRevision<>FRevision)or(Length(FPath)<2)then Exit;
  Title:=Trim(TitleEdit.Text);if Title=''then Title:=UiText('New route')+' '+FormatDateTime('dd.mm hh:nn',Now);
  Base:=Title;
  for I:=1 to Length(Base)do if(Base[I]<' ')or(Pos(Base[I],'<>:"/\|?*')>0)then Base[I]:='_';
  { Date suffix also avoids reserved Windows device names. Truncate by Unicode
    characters so a long Cyrillic title remains a valid filename. }
  Base:=UTF8Encode(Copy(UTF8Decode(Base),1,70))+'-'+FormatDateTime('yyyymmdd-hhnnss',Now);
  FileName:=UserRoutesDir+Base+'.gpx';N:=1;
  while FileExists(FileName)do begin Inc(N);FileName:=UserRoutesDir+Base+'-'+IntToStr(N)+'.gpx';end;
  try
    SavePlannerGPX(FileName,Title,FPath,FStops,LoopCheck.Checked);
    FStops:=nil;FSnapped:=nil;FPath:=nil;FCanUndo:=False;FSelected:=-1;SaveDraft;
    ViewMenu.OpenCloudRoute(FileName,(Sender<>nil)and(TComponent(Sender).Tag=1));
  except on E:Exception do Status.Caption:=UiText('Could not save: ')+E.Message;end;
end;
procedure TRouteCreatorPage.RememberUndo;
begin
  FUndoStops:=Copy(FStops);FUndoLoop:=LoopCheck.Checked;FCanUndo:=True;
end;
procedure TRouteCreatorPage.ClickUndo(Sender:TObject);
var I:Integer;S:TPlannerSnap;
begin
  if not FCanUndo then Exit;
  FStops:=Copy(FUndoStops);FLoadingDraft:=True;LoopCheck.Checked:=FUndoLoop;FLoadingDraft:=False;
  SetLength(FSnapped,Length(FStops));
  for I:=0 to High(FStops)do begin
    FSnapped[I]:=(FGraph<>nil)and FGraph.Snap(FStops[I],S);
    if FSnapped[I]then FStops[I]:=S.Position;
  end;
  FCanUndo:=False;FSelected:=High(FStops);InvalidateRoute;
end;
procedure TRouteCreatorPage.DraftChanged(Sender:TObject);
begin if not FLoadingDraft then FDraftDelay:=1;end;
procedure TRouteCreatorPage.SaveDraft;
var O:TJSONObject;A:TJSONArray;I:Integer;
begin
  O:=TJSONObject.Create(['title',TitleEdit.Text,'loop',LoopCheck.Checked,'zoom',Map.Zoom]);
  A:=TJSONArray.Create;O.Add('stops',A);
  for I:=0 to High(FStops)do A.Add(TJSONArray.Create([FStops[I].Lat,FStops[I].Lon]));
  try
    try WriteAccountJSON(UserDataDir+'drafts'+PathDelim+'route.json',O);
    except on E:Exception do Status.Caption:=UiText('Could not save: ')+E.Message;end;
  finally O.Free;end;
end;
procedure TRouteCreatorPage.LoadDraft;
var O:TJSONObject;A:TJSONArray;I:Integer;FileName:String;
begin
  FileName:=UserDataDir+'drafts'+PathDelim+'route.json';if not FileExists(FileName)then Exit;
  O:=nil;FLoadingDraft:=True;
  try
    try
      O:=ReadAccountJSON(FileName);TitleEdit.Text:=O.Get('title',UiText('New route'));LoopCheck.Checked:=O.Get('loop',False);
      if O.Find('stops')is TJSONArray then begin
        A:=O.Arrays['stops'];SetLength(FStops,A.Count);SetLength(FSnapped,A.Count);
        for I:=0 to A.Count-1 do FStops[I]:=TLatLon.Make(A.Arrays[I].Floats[0],A.Arrays[I].Floats[1]);
        if A.Count>0 then Map.CenterAt(FStops[0],O.Get('zoom',15));
      end;
    except on E:Exception do Status.Caption:=E.Message;end;
  finally O.Free;FLoadingDraft:=False;end;
end;

end.
