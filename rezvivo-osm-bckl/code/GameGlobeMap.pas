unit GameGlobeMap;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, SysUtils, fpjson, CastleUIControls, CastleViewport, CastleVectors, CastleScene,
  CastleKeysMouse, CastleImages, X3DNodes, Osm3dGeoMath, Osm3dFlatMap,
  GameGlobeMath, GameGlobePatch;
type
  TGlobeLine=record Id:Int64;Color:TVector4;Width:Single;Segments:array of array of TLatLon;end;
  TGlobeStroke=record Id:Int64;Color:TVector4;Width:Single;Count:Integer;Points,Triangles:array of TVector2;end;
  TGlobeTile=class
    Tile:TTileXY;Needed,Visible,Attempted,Detailed,DetailReady,DetailPartial,Pinned:Boolean;
    Texture:TPixelTextureNode;Task:TFlatMapTask;Patch:TGlobePatch;Used:QWord;
    RenderSource:TGlobeTile;RetryAt:QWord;Failures:Integer;
    destructor Destroy;override;
    procedure SetImage(Img:TCastleImage);
  end;
  TGlobeMap=class(TCastleViewport)
  private
    FCenter:TLatLon;FView:TGlobeProjection;FAltitude,FTargetAltitude:Double;
    FZoom,FRequestedZoom,FSizeStable:Integer;FDrag,FActive,FDirty,FMeshDirty,FRouteDirty:Boolean;
    FAnchor:TLatLon;FZoomAnchor:Boolean;FZoomPoint:TVector2;
    FDown:TVector2;FDelay,FLoadDelay:Single;FLastW,FLastH:Single;
    FWanted:TGlobeTiles;
    FLoadingPaused:Boolean;FUncovered:Integer;
    FSelectedId:Int64;FLines:array of TGlobeLine;FStrokes:array of TGlobeStroke;
    FTiles:TList;FNorth,FSouth:TGlobePatch;
    FScene:TCastleScene;FSceneRoot:TX3DRootNode;
    FOnChanged,FOnSelect:TNotifyEvent;
    FFitArea:TCastleUserInterface;
    procedure SyncProjection;
    procedure Changed;
    procedure PrepareTiles;
    procedure PrepareCoverage;
    procedure PositionPatches;
    function FindTile(const T:TTileXY;CreateMissing:Boolean):TGlobeTile;
    procedure ProjectRoutes;
    procedure SelectAt(const P:TVector2);
    procedure AnchorAt(const Geo:TLatLon;const Screen:TVector2);
    procedure RenderMapLines;
    procedure PaintOverlay;
  protected
    procedure RenderOverlay;virtual;
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure SetRoutes(A:TJSONArray;Fit:Boolean=False);
    procedure FitRoute(Id:Int64);
    function BoundsQuery:string;
    function VisibleBox:TLatLonBox;
    function GeoToScreen(const P:TLatLon):TVector2;
    function ScreenToGeo(const P:TVector2):TLatLon;
    function TryScreenToGeo(const P:TVector2;out Geo:TLatLon):Boolean;
    procedure CenterAt(const P:TLatLon;Zoom:Integer);
    procedure ShowPlanet;
    function MapStats:TJSONObject;
    procedure SetActive(Value:Boolean);
    procedure PauseTileLoading(Value:Boolean);
    function TileLoadingIdle:Boolean;
    procedure ZoomBy(Delta:Integer);
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    function Press(const Event:TInputPressRelease):Boolean;override;
    function Release(const Event:TInputPressRelease):Boolean;override;
    function Motion(const Event:TInputMotion):Boolean;override;
    property OnChanged:TNotifyEvent read FOnChanged write FOnChanged;
    property OnSelect:TNotifyEvent read FOnSelect write FOnSelect;
    property SelectedId:Int64 read FSelectedId write FSelectedId;
    property Zoom:Integer read FZoom;
    property FitArea:TCastleUserInterface read FFitArea write FFitArea;
    property TileLoadingPaused:Boolean read FLoadingPaused;
  end;
implementation
uses Math, CastleTransform, CastleRectangles, CastleColors, CastleGLUtils, CastleGLImages,
  CastleRenderContext, Osm3dStudioSettings, GameGlobeCoverage;
type
  TGlobeOverlay=class(TCastleUserInterface)
    Map:TGlobeMap;
    procedure Render;override;
  end;
procedure TGlobeOverlay.Render;
begin inherited;Map.PaintOverlay;end;
destructor TGlobeTile.Destroy;
begin
  Task.Free;Patch.Free;
  if Texture<>nil then begin Texture.KeepExistingEnd;Texture.FreeIfUnused;end;
  inherited;
end;
procedure TGlobeTile.SetImage(Img:TCastleImage);
var Old:TPixelTextureNode;Props:TTexturePropertiesNode;
begin
  Old:=Texture;Texture:=TPixelTextureNode.Create;Texture.KeepExistingBegin;
  Texture.FdImage.Value:=Img;Texture.RepeatS:=False;Texture.RepeatT:=False;
  Props:=TTexturePropertiesNode.Create;Props.MinificationFilter:=minLinearMipmapLinear;
  Props.MagnificationFilter:=magLinear;Props.AnisotropicDegree:=8;Texture.TextureProperties:=Props;
  if Old<>nil then begin Old.KeepExistingEnd;Old.FreeIfUnused;end;
end;
constructor TGlobeMap.Create(AOwner:TComponent);
var Overlay:TGlobeOverlay;
begin
  inherited;FTiles:=TList.Create;FCenter:=TLatLon.Make(35,35);
  FAltitude:=2.8;FTargetAltitude:=FAltitude;FRequestedZoom:=-1;
  FActive:=True;FDirty:=True;FMeshDirty:=True;FRouteDirty:=True;
  BackgroundColor:=Vector4(0.043,0.063,0.078,1);Transparent:=False;
  Camera.Perspective.FieldOfView:=GLOBE_FOV*Pi/180;Camera.Perspective.FieldOfViewAxis:=faVertical;
  { X3D texture nodes may be shared by shapes within one scene. Sharing them
    between separate TCastleScene instances breaks node and GPU ownership. }
  FSceneRoot:=TX3DRootNode.Create;
  FNorth:=TGlobePatch.CreatePatch(TTileXY.Make(0,0,2),1);FSceneRoot.AddChildren(FNorth.Node);
  FSouth:=TGlobePatch.CreatePatch(TTileXY.Make(0,0,2),-1);FSceneRoot.AddChildren(FSouth.Node);
  FScene:=TCastleScene.Create(Self);FScene.Load(FSceneRoot,True);
  FScene.ProcessEvents:=False;FScene.Pickable:=False;FScene.Collides:=False;Items.Add(FScene);
  { A viewport child gets CGE's ordinary 2D render state. Drawing directly
    after inherited viewport Render still uses its perspective/depth state. }
  Overlay:=TGlobeOverlay.Create(Self);Overlay.Map:=Self;Overlay.FullSize:=True;InsertFront(Overlay);
  SyncProjection;
end;
destructor TGlobeMap.Destroy;
var I:Integer;T:TGlobeTile;
begin
  for I:=0 to FTiles.Count-1 do begin T:=TGlobeTile(FTiles[I]);if T.Task<>nil then T.Task.Cancel;end;
  { Pinned nodes must be released while their CGE scene is still alive:
    FreeRootNode intentionally leaves Scene on nodes surviving root disposal. }
  FScene.BeginChangesSchedule;
  try
    for I:=0 to FTiles.Count-1 do begin T:=TGlobeTile(FTiles[I]);
      if T.Patch<>nil then begin FSceneRoot.RemoveChildren(T.Patch.Node);FreeAndNil(T.Patch);end;
    end;
    FSceneRoot.RemoveChildren(FNorth.Node);FreeAndNil(FNorth);
    FSceneRoot.RemoveChildren(FSouth.Node);FreeAndNil(FSouth);
  finally FScene.EndChangesSchedule;end;
  for I:=0 to FTiles.Count-1 do TObject(FTiles[I]).Free;FTiles.Free;
  Items.Remove(FScene);FreeAndNil(FScene);FSceneRoot:=nil;
  inherited;
end;
procedure TGlobeMap.SyncProjection;
var R:TFloatRectangle;
begin
  R:=RenderRect;FView.Setup(FCenter,FAltitude,Max(100,R.Width),Max(100,R.Height));
  FZoom:=EnsureRange(Floor(FView.NominalZoom+0.0001),0,18);
  Camera.SetView(Vector3(0,0,FAltitude),Vector3(0,0,-1),Vector3(0,1,0));
  Camera.ProjectionNear:=FAltitude*0.1;Camera.ProjectionFar:=FAltitude+2.1;
end;
procedure TGlobeMap.SetActive(Value:Boolean);
var I:Integer;T:TGlobeTile;
begin
  FActive:=Value;FDrag:=False;FZoomAnchor:=False;
  if Value then Changed else for I:=0 to FTiles.Count-1 do begin
    T:=TGlobeTile(FTiles[I]);if T.Task<>nil then begin T.Task.Cancel;T.Attempted:=T.Texture<>nil;T.Detailed:=T.DetailReady;end;
  end;
end;
procedure TGlobeMap.Changed;
begin
  FCenter.Lat:=EnsureRange(FCenter.Lat,-89.9999,89.9999);FCenter.Lon:=GlobeWrapLon(FCenter.Lon);
  SyncProjection;FDirty:=True;FMeshDirty:=True;FRouteDirty:=True;FDelay:=0.25;FLoadDelay:=0.12;
end;
procedure TGlobeMap.PauseTileLoading(Value:Boolean);
var I:Integer;T:TGlobeTile;
begin
  FLoadingPaused:=Value;
  if Value then for I:=0 to FTiles.Count-1 do begin
    T:=TGlobeTile(FTiles[I]);if T.Task<>nil then T.Task.Cancel;
  end;
end;
function TGlobeMap.TileLoadingIdle:Boolean;
var I:Integer;T:TGlobeTile;
begin
  Result:=False;
  for I:=0 to FTiles.Count-1 do begin
    T:=TGlobeTile(FTiles[I]);
    if(T.Task<>nil)and not T.Task.Done then Exit;
  end;
  Result:=True;
end;
procedure TGlobeMap.CenterAt(const P:TLatLon;Zoom:Integer);
begin
  if IsNan(P.Lat)or IsInfinite(P.Lat)or IsNan(P.Lon)or IsInfinite(P.Lon)then Exit;
  FCenter:=P;FRequestedZoom:=EnsureRange(Zoom,0,18);FZoomAnchor:=False;Changed;
end;
procedure TGlobeMap.ShowPlanet;
begin FRequestedZoom:=-1;FZoomAnchor:=False;FTargetAltitude:=2.8;end;
procedure TGlobeMap.ZoomBy(Delta:Integer);
begin
  FRequestedZoom:=-1;FZoomAnchor:=False;
  FTargetAltitude:=EnsureRange(FTargetAltitude*Power(2,-Delta),FView.AltitudeForZoom(18),GLOBE_MAX_ALTITUDE);
end;
function TGlobeMap.GeoToScreen(const P:TLatLon):TVector2;
var X,Y:Double;R:TFloatRectangle;
begin
  R:=RenderRect;if FView.Project(P,X,Y)then Result:=Vector2(R.Left+X,R.Bottom+Y)else Result:=Vector2(-1E20,-1E20);
end;
function TGlobeMap.TryScreenToGeo(const P:TVector2;out Geo:TLatLon):Boolean;
var R:TFloatRectangle;
begin
  R:=RenderRect;Result:=(P.X>=R.Left)and(P.X<=R.Right)and(P.Y>=R.Bottom)and(P.Y<=R.Top);
  if Result then Result:=FView.Pick(P.X-R.Left,P.Y-R.Bottom,Geo);
end;
function TGlobeMap.ScreenToGeo(const P:TVector2):TLatLon;
begin if not TryScreenToGeo(P,Result)then Result:=FCenter;end;
procedure TGlobeMap.AnchorAt(const Geo:TLatLon;const Screen:TVector2);
var I:Integer;X,Y,U,V,A,B,C,D,Det,DL,DA:Double;Test:TGlobeProjection;R:TFloatRectangle;
const E=0.00001;
begin
  R:=RenderRect;
  for I:=0 to 5 do begin
    if not FView.Project(Geo,X,Y)then Break;
    U:=Screen.X-R.Left-X;V:=Screen.Y-R.Bottom-Y;if Abs(U)+Abs(V)<0.005 then Break;
    Test:=FView;Test.Center.Lat:=Test.Center.Lat+E;Test.Project(Geo,A,C);A:=(A-X)/E;C:=(C-Y)/E;
    Test:=FView;Test.Center.Lon:=Test.Center.Lon+E;Test.Project(Geo,B,D);B:=(B-X)/E;D:=(D-Y)/E;
    Det:=A*D-B*C;if Abs(Det)<1E-12 then Break;
    DA:=EnsureRange((U*D-B*V)/Det,-20.0,20.0);DL:=EnsureRange((A*V-U*C)/Det,-30.0,30.0);
    FCenter.Lat:=EnsureRange(FCenter.Lat+DA,-89.9999,89.9999);FCenter.Lon:=GlobeWrapLon(FCenter.Lon+DL);SyncProjection;
  end;
  Changed;
end;
function TGlobeMap.VisibleBox:TLatLonBox;
begin
  Result:=FView.Bounds;
  { The routing service accepts one ordinary bbox; never issue a globe-wide
    road query merely because a street view straddles the date line. }
  Result.MinLon:=Max(-180,Result.MinLon);Result.MaxLon:=Min(180,Result.MaxLon);
  Result.MinLat:=Max(-85.05112878,Result.MinLat);Result.MaxLat:=Min(85.05112878,Result.MaxLat);
end;
function TGlobeMap.BoundsQuery:string;
var B:TLatLonBox;FS:TFormatSettings;
begin
  B:=FView.Bounds;if(B.MinLon< -180)or(B.MaxLon>180)then begin B.MinLon:=-180;B.MaxLon:=180;end;
  FS:=DefaultFormatSettings;FS.DecimalSeparator:='.';
  Result:=Format('%.7f,%.7f,%.7f,%.7f',[B.MinLon,B.MinLat,B.MaxLon,B.MaxLat],FS);
end;
function TGlobeMap.FindTile(const T:TTileXY;CreateMissing:Boolean):TGlobeTile;
var I:Integer;
begin
  for I:=0 to FTiles.Count-1 do begin Result:=TGlobeTile(FTiles[I]);if(Result.Tile.X=T.X)and(Result.Tile.Y=T.Y)and(Result.Tile.Zoom=T.Zoom)then Exit;end;
  Result:=nil;if CreateMissing then begin Result:=TGlobeTile.Create;Result.Tile:=T;FTiles.Add(Result);end;
end;
procedure TGlobeMap.PrepareTiles;
var I,Z:Integer;T,A:TGlobeTile;
begin
  FWanted:=FView.Tiles;
  for I:=0 to FTiles.Count-1 do begin T:=TGlobeTile(FTiles[I]);T.Visible:=False;T.Needed:=False;end;
  T:=FindTile(TTileXY.Make(0,0,0),True);T.Needed:=True;
  for I:=0 to High(FWanted)do begin
    T:=FindTile(FWanted[I],True);T.Visible:=True;T.Needed:=True;T.Used:=GetTickCount64;
    Z:=Min(10,T.Tile.Zoom);A:=FindTile(TTileXY.Make(T.Tile.X shr(T.Tile.Zoom-Z),T.Tile.Y shr(T.Tile.Zoom-Z),Z),True);A.Needed:=True;
  end;
end;
procedure TGlobeMap.PrepareCoverage;
var I,N:Integer;T,A:TGlobeTile;Available:TGlobeTextureInfos;
    Sources:array of TGlobeTile;Coverage:TGlobeCoveragePieces;
begin
  SetLength(Available,FTiles.Count);SetLength(Sources,FTiles.Count);N:=0;
  for I:=0 to FTiles.Count-1 do begin
    T:=TGlobeTile(FTiles[I]);T.RenderSource:=nil;T.Pinned:=False;
    if T.Texture<>nil then begin
      Sources[N]:=T;Available[N].Tile:=T.Tile;
      if T.DetailReady or T.DetailPartial then Available[N].Quality:=T.Tile.Zoom else Available[N].Quality:=Min(FLAT_MAP_WORLD_ZOOM,T.Tile.Zoom);
      Inc(N);
    end;
  end;
  SetLength(Available,N);Coverage:=GlobeCoverage(FWanted,Available);FUncovered:=0;
  for I:=0 to High(Coverage)do begin
    if Coverage[I].Source<0 then begin Inc(FUncovered);Continue;end;
    T:=FindTile(Coverage[I].Tile,True);A:=Sources[Coverage[I].Source];
    T.RenderSource:=A;T.Pinned:=True;A.Pinned:=True;A.Used:=GetTickCount64;
  end;
  for I:=0 to FTiles.Count-1 do begin
    T:=TGlobeTile(FTiles[I]);
    if(T.RenderSource<>nil)and(T.Patch=nil)then begin
      T.Patch:=TGlobePatch.CreatePatch(T.Tile);FSceneRoot.AddChildren(T.Patch.Node);
    end;
    if(T.RenderSource=nil)and(T.Patch<>nil)then begin FSceneRoot.RemoveChildren(T.Patch.Node);FreeAndNil(T.Patch);end;
  end;
end;
procedure TGlobeMap.PositionPatches;
var I:Integer;T:TGlobeTile;
begin
  FScene.BeginChangesSchedule;
  try
  PrepareCoverage;
  FNorth.Exists:=FView.PoleVisible(1);if FNorth.Exists then FNorth.Position(FView);
  FSouth.Exists:=FView.PoleVisible(-1);if FSouth.Exists then FSouth.Position(FView);
  for I:=0 to FTiles.Count-1 do begin T:=TGlobeTile(FTiles[I]);if T.Patch=nil then Continue;
    T.Patch.Position(FView);T.Patch.UseTexture(T.RenderSource.Texture,T.RenderSource.Tile);T.Patch.Exists:=True;
  end;
  finally FScene.EndChangesSchedule;end;
end;
procedure TGlobeMap.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var I,Active,Pass,Uploads:Integer;T,Best:TGlobeTile;Img:TCastleImage;NewAlt:Double;NowTick:QWord;
    FinishedTask,Partial:Boolean;
  function Distance(Tile:TGlobeTile):Double;
  var Center:TTileXY;DX,DY:Double;
  begin
    Center:=TTileMath.LatLonToTile(FCenter,Tile.Tile.Zoom);
    DX:=Abs(Double(Tile.Tile.X)-Center.X);DX:=Min(DX,(1 shl Tile.Tile.Zoom)-DX);
    DY:=Double(Tile.Tile.Y)-Center.Y;Result:=Sqr(DX)+Sqr(DY);
  end;
begin
  inherited;if not FActive then Exit;
  if(FLastW<>RenderRect.Width)or(FLastH<>RenderRect.Height)then begin
    FLastW:=RenderRect.Width;FLastH:=RenderRect.Height;FSizeStable:=0;Changed;
  end else FSizeStable:=Min(2,FSizeStable+1);
  if(FRequestedZoom>=0)and(FSizeStable>=2)then begin
    FAltitude:=FView.AltitudeForZoom(FRequestedZoom);FTargetAltitude:=FAltitude;FRequestedZoom:=-1;Changed;
  end;
  if Abs(Ln(FAltitude/FTargetAltitude))>0.00001 then begin
    NewAlt:=Exp(Ln(FAltitude)+(Ln(FTargetAltitude)-Ln(FAltitude))*(1-Exp(-14*SecondsPassed)));
    if Abs(Ln(NewAlt/FTargetAltitude))<0.001 then NewAlt:=FTargetAltitude;
    FAltitude:=NewAlt;Changed;if FZoomAnchor then AnchorAt(FAnchor,FZoomPoint);
  end;
  if FDirty then begin PrepareTiles;FDirty:=False;end;
  FLoadDelay:=Max(0,FLoadDelay-SecondsPassed);NowTick:=GetTickCount64;Active:=0;Uploads:=0;
  for I:=FTiles.Count-1 downto 0 do begin T:=TGlobeTile(FTiles[I]);
    if T.Task<>nil then begin
      if not T.Needed then begin T.Task.Cancel;T.Attempted:=T.Texture<>nil;T.Detailed:=T.DetailReady;end;
      FinishedTask:=T.Task.Done;
      if Uploads<1 then begin
        Img:=T.Task.TakeImage(Partial);
        if Img<>nil then begin
          T.DetailPartial:=Partial;T.DetailReady:=not Partial and T.Task.Detailed;
          { A cached plain OSM tile is a valid detailed fallback, but the
            normal detail pass must still get a chance to add available DEM. }
          if not Partial then T.Detailed:=T.DetailReady and not T.Task.CachedOnly;T.SetImage(Img);
          T.Failures:=0;T.RetryAt:=0;Inc(Uploads);FMeshDirty:=True;
        end;
        if FinishedTask then begin
          if T.Task.Cancelled then begin
            T.Attempted:=T.Texture<>nil;T.Detailed:=T.DetailReady;T.RetryAt:=0;
          end else if not T.Task.FinalTaken and not T.Task.CachedOnly then begin
            if T.Task.RequestedDetail then T.Detailed:=T.DetailReady else T.Attempted:=False;
            T.Failures:=Min(4,T.Failures+1);T.RetryAt:=NowTick+QWord(1000 shl T.Failures);
          end;
          FreeAndNil(T.Task);
        end;
      end;
      if T.Task<>nil then Inc(Active);
    end;
  end;
  { Request low-resolution coverage first; keep it on the same spherical
    patches until their detailed textures arrive. No overlapping shells. }
  for Pass:=0 to 1 do while(Active<FlatMapWorkerLimit)and not FLoadingPaused do begin
    Best:=nil;
    for I:=0 to FTiles.Count-1 do begin T:=TGlobeTile(FTiles[I]);
      if not T.Needed or(T.Task<>nil)or(T.RetryAt>NowTick)then Continue;
      if(Pass=0)and T.Attempted then Continue;
      if(Pass=0)and(T.Tile.Zoom>FLAT_MAP_WORLD_ZOOM)and(T.Tile.Zoom<FLAT_MAP_DETAIL_ZOOM)then Continue;
      if(Pass=1)and(not T.Visible or not T.Attempted or T.Detailed or(T.Tile.Zoom<FLAT_MAP_DETAIL_ZOOM))then Continue;
      if(Pass=1)and(FLoadDelay>0)then Continue;
      if(Best=nil)or(T.Tile.Zoom<Best.Tile.Zoom)or
        ((Pass=1)and(T.Tile.Zoom=Best.Tile.Zoom)and(Distance(T)<Distance(Best)))then Best:=T;
    end;
    if Best=nil then Break;T:=Best;
    if Pass=0 then T.Attempted:=True else T.Detailed:=True;
    { A cropped z10 overview is not a z16 texture. Read any existing detail
      from disk first; otherwise render with the best live neighbouring LOD. }
    T.Task:=TFlatMapTask.Create(T.Tile.Zoom,T.Tile.X,T.Tile.Y,DefaultCacheRoot,Pass=1,
      (Pass=0)and(T.Tile.Zoom>=FLAT_MAP_DETAIL_ZOOM));T.Task.Start;Inc(Active);
  end;
  if FMeshDirty then begin PositionPatches;FMeshDirty:=False;end;
  { Active coverage pins its sources, including ancestors and descendants. }
  while FTiles.Count>192 do begin
    Best:=nil;
    for I:=0 to FTiles.Count-1 do begin T:=TGlobeTile(FTiles[I]);if T.Needed or T.Pinned or(T.Task<>nil)then Continue;
      if(Best=nil)or(T.Used<Best.Used)then Best:=T;
    end;
    if Best=nil then Break;FTiles.Remove(Best);Best.Free;
  end;
  if FDelay>0 then begin FDelay:=FDelay-SecondsPassed;
    if(FDelay<=0)and not FDrag and Assigned(FOnChanged)then FOnChanged(Self);
  end;
end;
function TGlobeMap.MapStats:TJSONObject;
var I,V,R,D,P,Partial,MinZ,MaxZ,Rendered,Fallback,FromDetail:Integer;T:TGlobeTile;Workers:TFlatMapWorkerStats;
begin
  V:=0;R:=0;D:=0;P:=0;Partial:=0;MinZ:=18;MaxZ:=0;Rendered:=0;Fallback:=0;FromDetail:=0;
  for I:=0 to FTiles.Count-1 do begin T:=TGlobeTile(FTiles[I]);
    if T.RenderSource<>nil then begin
      Inc(Rendered);if T.RenderSource<>T then Inc(Fallback);if T.RenderSource.DetailReady then Inc(FromDetail);
    end;
    if not T.Visible then Continue;
    Inc(V);MinZ:=Min(MinZ,T.Tile.Zoom);MaxZ:=Max(MaxZ,T.Tile.Zoom);
    if T.Texture<>nil then Inc(R);if T.DetailReady then Inc(D);if T.DetailPartial then Inc(Partial);if T.Task<>nil then Inc(P);
  end;
  Result:=TJSONObject.Create(['globe',True,'zoom',FZoom,'lat',FCenter.Lat,'lon',FCenter.Lon,
    'altitude_m',FAltitude*6371000,'visible',V,'ready',R,'detailed',D,'pending',P,'min_lod',MinZ,'max_lod',MaxZ,'cached',FTiles.Count,
    'rendered',Rendered,'fallback',Fallback,'rendered_detail',FromDetail,'uncovered',FUncovered,'loading_paused',FLoadingPaused]);
  Workers:=FlatMapWorkerStats;
  Result.Add('exists',Exists);Result.Add('active',FActive);
  Result.Add('rect',TJSONArray.Create([RenderRect.Left,RenderRect.Bottom,RenderRect.Width,RenderRect.Height]));
  Result.Add('partial',Partial);Result.Add('osm_min_zoom',FLAT_MAP_DETAIL_ZOOM);Result.Add('street_min_zoom',FLAT_MAP_STREET_ZOOM);
  Result.Add('workers',TJSONObject.Create(['limit',Workers.Limit,'active',Workers.Active,'peak',Workers.Peak,
    'builds',Int64(Workers.Builds),'sources',Workers.Sources,'loading_sources',Workers.LoadingSources,
    'pinned_sources',Workers.PinnedSources,'source_loads',Int64(Workers.SourceLoads),'source_waits',Int64(Workers.SourceWaits),
    'osm_requests',Workers.OsmRequests,'osm_requests_peak',Workers.OsmRequestsPeak]));
end;
procedure TGlobeMap.SetRoutes(A:TJSONArray;Fit:Boolean);
var I,J,K:Integer;O:TJSONObject;D:TJSONData;Segments,Seg,XY:TJSONArray;
begin
  SetLength(FLines,A.Count);
  for I:=0 to A.Count-1 do begin
    O:=TJSONObject(A[I]);FLines[I].Id:=O.Get('id',Int64(0));D:=O.Find('map_path');if not(D is TJSONArray)then D:=O.Find('preview_path');
    FLines[I].Width:=EnsureRange(O.Get('line_width',3.0),1.0,12.0);
    FLines[I].Color:=Vector4(0,0,0,0);D:=O.Find('line_color');
    if(D is TJSONArray)and(D.Count=4)then
      FLines[I].Color:=Vector4(D.Items[0].AsFloat,D.Items[1].AsFloat,D.Items[2].AsFloat,D.Items[3].AsFloat);
    D:=O.Find('map_path');if not(D is TJSONArray)then D:=O.Find('preview_path');
    FLines[I].Segments:=nil;if not(D is TJSONArray)then Continue;Segments:=TJSONArray(D);SetLength(FLines[I].Segments,Segments.Count);
    for J:=0 to Segments.Count-1 do begin Seg:=TJSONArray(Segments[J]);SetLength(FLines[I].Segments[J],Seg.Count);
      for K:=0 to Seg.Count-1 do begin XY:=TJSONArray(Seg[K]);FLines[I].Segments[J][K]:=TLatLon.Make(XY[1].AsFloat,XY[0].AsFloat);end;
    end;
  end;
  FRouteDirty:=True;if Fit then FitRoute(0);
end;
procedure TGlobeMap.FitRoute(Id:Int64);
var I,J,K,Z:Integer;P,RouteCenter:TLatLon;Found,Fits:Boolean;MinA,MaxA,MinL,MaxL,L,Ref,X,Y:Double;
  Area:TFloatRectangle;
begin
  Area:=RenderRect;
  if(FFitArea<>nil)and(FFitArea.RenderRect.Width>80)and(FFitArea.RenderRect.Height>80)then
    Area:=FFitArea.RenderRect;
  Found:=False;MinA:=90;MaxA:=-90;MinL:=1E10;MaxL:=-1E10;Ref:=FCenter.Lon;
  for I:=0 to High(FLines)do if(Id=0)or(FLines[I].Id=Id)then
    for J:=0 to High(FLines[I].Segments)do for K:=0 to High(FLines[I].Segments[J])do begin
      P:=FLines[I].Segments[J][K];if not Found then Ref:=P.Lon;Found:=True;
      L:=Ref+GlobeWrapLon(P.Lon-Ref);MinL:=Min(MinL,L);MaxL:=Max(MaxL,L);MinA:=Min(MinA,P.Lat);MaxA:=Max(MaxA,P.Lat);
    end;
  if not Found then Exit;RouteCenter:=TLatLon.Make((MinA+MaxA)/2,GlobeWrapLon((MinL+MaxL)/2));FCenter:=RouteCenter;
  FAltitude:=2.8;SyncProjection;
  for Z:=15 downto 0 do begin
    FCenter:=RouteCenter;FAltitude:=FView.AltitudeForZoom(Z);SyncProjection;Fits:=True;
    if FFitArea<>nil then AnchorAt(RouteCenter,Vector2(Area.Left+Area.Width/2,Area.Bottom+Area.Height/2));
    for J:=0 to 1 do for K:=0 to 1 do begin
      P:=TLatLon.Make(MinA+(MaxA-MinA)*J,MinL+(MaxL-MinL)*K);
      if not FView.Project(P,X,Y)or(X<Area.Left-RenderRect.Left+24)or
        (X>Area.Right-RenderRect.Left-24)or(Y<Area.Bottom-RenderRect.Bottom+24)or
        (Y>Area.Top-RenderRect.Bottom-24)then Fits:=False;
    end;
    if Fits then Break;
  end;
  FTargetAltitude:=FAltitude;FRequestedZoom:=-1;Changed;
end;
procedure TGlobeMap.ProjectRoutes;
var I,J,K,S,N,C,Stroke:Integer;A,B,P:TLatLon;X,Y,Dist:Double;LastValid,Valid:Boolean;Q,U,V,Offset:TVector2;
begin
  FStrokes:=nil;Stroke:=-1;
  for I:=0 to High(FLines)do for J:=0 to High(FLines[I].Segments)do begin
    LastValid:=False;
    for K:=1 to High(FLines[I].Segments[J])do begin
      A:=FLines[I].Segments[J][K-1];B:=FLines[I].Segments[J][K];
      Dist:=Max(Abs(B.Lat-A.Lat),Abs(GlobeWrapLon(B.Lon-A.Lon)));N:=Max(1,Ceil(Dist));
      for S:=0 to N do begin
        if(S=0)and(K>1)then Continue;
        P:=TLatLon.Make(A.Lat+(B.Lat-A.Lat)*S/N,A.Lon+GlobeWrapLon(B.Lon-A.Lon)*S/N);
        Valid:=FView.Project(P,X,Y);
        if Valid then begin
          if not LastValid then begin Stroke:=Length(FStrokes);SetLength(FStrokes,Stroke+1);FStrokes[Stroke].Id:=FLines[I].Id;
            FStrokes[Stroke].Color:=FLines[I].Color;FStrokes[Stroke].Width:=FLines[I].Width;end;
          Q:=Vector2(RenderRect.Left+X,RenderRect.Bottom+Y);C:=FStrokes[Stroke].Count;
          if C=Length(FStrokes[Stroke].Points)then SetLength(FStrokes[Stroke].Points,Max(64,C*2));
          FStrokes[Stroke].Points[C]:=Q;Inc(FStrokes[Stroke].Count);
        end;
        LastValid:=Valid;
      end;
    end;
  end;
  { Cache a three-pixel ribbon: wide GL lines are not supported consistently
    across drivers. Rebuild only when the route or camera changes. }
  for I:=0 to High(FStrokes)do begin
    C:=FStrokes[I].Count;SetLength(FStrokes[I].Points,C);
    SetLength(FStrokes[I].Triangles,Max(0,C-1)*6);
    for K:=1 to C-1 do begin
      U:=FStrokes[I].Points[K-1];V:=FStrokes[I].Points[K];
      X:=V.X-U.X;Y:=V.Y-U.Y;Dist:=Max(0.0001,Sqrt(X*X+Y*Y));
      Offset:=Vector2(-Y/Dist*FStrokes[I].Width*0.5,X/Dist*FStrokes[I].Width*0.5);N:=(K-1)*6;
      FStrokes[I].Triangles[N]:=U+Offset;FStrokes[I].Triangles[N+1]:=U-Offset;
      FStrokes[I].Triangles[N+2]:=V+Offset;FStrokes[I].Triangles[N+3]:=V+Offset;
      FStrokes[I].Triangles[N+4]:=U-Offset;FStrokes[I].Triangles[N+5]:=V-Offset;
    end;
  end;
  FRouteDirty:=False;
end;
procedure TGlobeMap.RenderMapLines;
var I:Integer;Color:TCastleColor;
begin
  if FRouteDirty then ProjectRoutes;
  for I:=0 to High(FStrokes)do if Length(FStrokes[I].Points)>1 then begin
    if FStrokes[I].Color.W>0 then Color:=FStrokes[I].Color
    else if FStrokes[I].Id=FSelectedId then Color:=Vector4(0.95,0.18,0.33,1)else Color:=Vector4(0.02,0.43,0.85,1);
    DrawPrimitive2D(pmTriangles,FStrokes[I].Triangles,Color);
  end;
end;
procedure TGlobeMap.RenderOverlay;
begin end;
procedure TGlobeMap.PaintOverlay;
var R:TFloatRectangle;Clip:TScissor;
begin
  R:=RenderRect;if(R.Width<=0)or(R.Height<=0)then Exit;
  Clip:=TScissor.Create;Clip.Rect:=Rectangle(Round(R.Left),Round(R.Bottom),Round(R.Width),Round(R.Height));Clip.Enabled:=True;
  try RenderMapLines;RenderOverlay;finally Clip.Free;end;
end;
procedure TGlobeMap.SelectAt(const P:TVector2);
var I,K:Integer;A,B:TVector2;DX,DY,T,E,Best:Double;Id:Int64;
begin
  if FRouteDirty then ProjectRoutes;Best:=144;Id:=0;
  for I:=0 to High(FStrokes)do for K:=1 to High(FStrokes[I].Points)do begin
    A:=FStrokes[I].Points[K-1];B:=FStrokes[I].Points[K];DX:=B.X-A.X;DY:=B.Y-A.Y;
    T:=EnsureRange(((P.X-A.X)*DX+(P.Y-A.Y)*DY)/Max(1E-12,DX*DX+DY*DY),0.0,1.0);
    E:=Sqr(P.X-A.X-T*DX)+Sqr(P.Y-A.Y-T*DY);if E<Best then begin Best:=E;Id:=FStrokes[I].Id;end;
  end;
  if Id<>0 then begin FSelectedId:=Id;if Assigned(FOnSelect)then FOnSelect(Self);end;
end;
function TGlobeMap.Press(const Event:TInputPressRelease):Boolean;
var R:TFloatRectangle;P:TLatLon;
begin
  Result:=inherited;R:=RenderRect;
  if(Event.Position.X<R.Left)or(Event.Position.X>R.Right)or(Event.Position.Y<R.Bottom)or(Event.Position.Y>R.Top)then Exit;
  if Event.IsMouseWheel(mwUp)or Event.IsMouseWheel(mwDown)then begin
    if Event.IsMouseWheel(mwUp)then ZoomBy(1)else ZoomBy(-1);
    FZoomAnchor:=TryScreenToGeo(Event.Position,FAnchor);FZoomPoint:=Event.Position;Exit(True);
  end;
  if Event.IsMouseButton(buttonLeft)and TryScreenToGeo(Event.Position,P)then begin
    FDrag:=True;FZoomAnchor:=False;FAnchor:=P;FDown:=Event.Position;Exit(True);
  end;
end;
function TGlobeMap.Motion(const Event:TInputMotion):Boolean;
begin Result:=inherited;if not FDrag then Exit;AnchorAt(FAnchor,Event.Position);Result:=True;end;
function TGlobeMap.Release(const Event:TInputPressRelease):Boolean;
begin
  Result:=inherited;if FDrag and Event.IsMouseButton(buttonLeft)then begin FDrag:=False;
    if Sqr(Event.Position.X-FDown.X)+Sqr(Event.Position.Y-FDown.Y)<25 then SelectAt(Event.Position)else Changed;Result:=True;
  end;
end;
end.
