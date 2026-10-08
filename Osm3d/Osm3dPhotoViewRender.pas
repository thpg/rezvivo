unit Osm3dPhotoViewRender;
{$mode objfpc}{$H+}

{ On-demand photo comparison on the ordinary renderer. No extra render loop. }
interface
uses SysUtils, fpjson, CastleViewport, CastleVectors, CastleTransform, CastleRectangles,
  Osm3dStreamingLauncher;
type
  TPhotoViewRender = class
  private
    FView:TJSONObject;
    FViewport:TCastleViewport;
    FSession:TOsm3dStreamingSession;
    FPosition,FDirection,FUp,FSavedPosition,FSavedDirection,FSavedUp:TVector3;
    FSavedFov,FAppliedFov:Single;
    FSavedAxis:TFieldOfViewAxis;
    FFrame:QWord;
    FRemembered:Boolean;
    FRect,FCrop:TRectangle;
    function FrameRect(V:TCastleViewport):TRectangle;
    procedure Ready(V:TCastleViewport; S:TOsm3dStreamingSession);
  public
    destructor Destroy; override;
    procedure Remember(V:TCastleViewport; S:TOsm3dStreamingSession);
    procedure ClearApplied;
    procedure Reset;
    function Sample(V:TCastleViewport; S:TOsm3dStreamingSession):TJSONObject;
    function Apply(View:TJSONObject; V:TCastleViewport; S:TOsm3dStreamingSession):TJSONObject;
    function Capture(const Path:string; Width:Integer; V:TCastleViewport; S:TOsm3dStreamingSession):TJSONObject;
    function Restore(V:TCastleViewport; S:TOsm3dStreamingSession):TJSONObject;
    function Active:Boolean;
  end;
implementation
uses Math, MD5, CastleImages, CastleTimeUtils, Osm3dPhotoView, Osm3dGeoMath, Osm3dTileKnowledge;

destructor TPhotoViewRender.Destroy;
begin FView.Free; inherited end;
function TPhotoViewRender.Active:Boolean;
begin Result:=FView<>nil end;

procedure TPhotoViewRender.ClearApplied;
begin FreeAndNil(FView) end;
procedure TPhotoViewRender.Reset;
begin ClearApplied; FViewport:=nil; FSession:=nil; FRemembered:=False end;
procedure TPhotoViewRender.Remember(V:TCastleViewport; S:TOsm3dStreamingSession);
begin
  Ready(V,S);
  if FRemembered and (FViewport=V) and (FSession=S) then Exit;
  V.Camera.GetWorldView(FSavedPosition,FSavedDirection,FSavedUp);
  FSavedFov:=V.Camera.Perspective.FieldOfView; FSavedAxis:=V.Camera.Perspective.FieldOfViewAxis;
  FViewport:=V; FSession:=S; FRemembered:=True;
end;

procedure TPhotoViewRender.Ready(V:TCastleViewport; S:TOsm3dStreamingSession);
begin
  if (V=nil) or (V.Camera=nil) or (V.Container=nil) or (S=nil) or (S.Map=nil) then raise Exception.Create('Photo comparison requires an active real 3D map');
end;

function TPhotoViewRender.FrameRect(V:TCastleViewport):TRectangle;
begin
  Result:=V.RenderRect.Round;
  if (Result.Width<16) or (Result.Height<16) then raise Exception.Create('Photo comparison viewport is too small');
end;

function TPhotoViewRender.Sample(V:TCastleViewport; S:TOsm3dStreamingSession):TJSONObject;
var P,D,U:TVector3; LL:TLatLon; C:TJSONObject; Rect:TRectangle; Y:Single; Fov:Double;
begin
  Ready(V,S); Rect:=FrameRect(V); V.Camera.GetWorldView(P,D,U); LL:=S.CameraGeo(P.X,P.Z);
  Fov:=V.Camera.Perspective.EffectiveFieldOfView.Y;
  if Fov<=0 then raise Exception.Create('Photo comparison: camera has not rendered yet');
  C:=PhotoCameraFromVectors(LL.Lat,LL.Lon,P.Y,S.Map.WorldScaleLatitude,RadToDeg(Fov),Rect.Width/Rect.Height,D,U);
  if S.Map.GroundYAt(P.X,P.Z,Y) then begin C.Add('ground_elevation_m',Y); C.Add('height_above_ground_m',P.Y-Y) end;
  Result:=TJSONObject.Create(['camera',C,'viewport_width',Rect.Width,'viewport_height',Rect.Height,
    'pending_tiles',S.Map.PendingTileWork,'generator_hash',S.GenHash,'recipe_hash',S.Map.KnowledgeRecipeHash]);
end;

function TPhotoViewRender.Apply(View:TJSONObject; V:TCastleViewport; S:TOsm3dStreamingSession):TJSONObject;
var C:TJSONObject; Asp,ViewportAsp,Fov:Double; Rect,Crop:TRectangle;
begin
  Ready(V,S); ValidatePhotoView(View); C:=TJSONObject(View.Find('camera'));
  if Abs(C.Get('scale_latitude_deg',0.0)-S.Map.WorldScaleLatitude)>0.00001 then
    raise Exception.Create('Photo comparison: map projection scale differs from the saved view');
  Rect:=FrameRect(V); Crop:=Rect; Asp:=C.Get('aspect_ratio',1.0); ViewportAsp:=Rect.Width/Rect.Height;
  if ViewportAsp>Asp then begin
    Crop.Width:=Round(Rect.Height*Asp); Crop.Left:=Rect.Left+(Rect.Width-Crop.Width) div 2;
  end else begin
    Crop.Height:=Round(Rect.Width/Asp); Crop.Bottom:=Rect.Bottom+(Rect.Height-Crop.Height) div 2;
  end;
  if (Crop.Width<16) or (Crop.Height<16) then raise Exception.Create('Photo comparison: crop is too small; enlarge the viewport');
  Fov:=2*ArcTan(Tan(DegToRad(C.Get('vertical_fov_deg',45.0))/2)*Rect.Height/Crop.Height);
  if Fov>=DegToRad(165) then raise Exception.Create('Photo comparison: viewport aspect requires too wide a lens; resize the window');
  Remember(V,S);
  FreeAndNil(FView); FView:=TJSONObject(View.Clone); FViewport:=V; FSession:=S;
  FRect:=Rect; FCrop:=Crop;
  FPosition:=S.GeoToLocal(TLatLon.Make(C.Get('latitude',0.0),C.Get('longitude',0.0))); FPosition.Y:=C.Get('elevation_m',0.0);
  PhotoCameraBasis(C,FDirection,FUp); FAppliedFov:=Fov;
  V.Camera.SetWorldView(FPosition,FDirection,FUp); V.Camera.Perspective.FieldOfViewAxis:=faVertical;
  { CGE converts the basis to its internal rotation and orthonormalizes it.
    Near-horizontal directions can change Up by a few float ULPs. Guard
    against subsequent movement using the actual applied basis, not the
    pre-conversion vectors. }
  V.Camera.GetWorldView(FPosition,FDirection,FUp);
  V.Camera.Perspective.FieldOfView:=FAppliedFov; FFrame:=TFramesPerSecond.RenderFrameId;
  Result:=TJSONObject.Create(['applied',True,'view_id',View.Get('id',''),'pending_tiles',S.Map.PendingTileWork,
    'capture_crop_px',TJSONArray.Create([FCrop.Left,FCrop.Bottom,FCrop.Width,FCrop.Height]),
    'note','Central crop preserves the photo lens without stretching the viewport. Capture after rendering and tile preparation.']);
end;

function TPhotoViewRender.Capture(const Path:string; Width:Integer; V:TCastleViewport; S:TOsm3dStreamingSession):TJSONObject;
var P,D,U:TVector3; Rect:TRectangle; Img:TRGBImage; Meta:TJSONObject; Height:Integer; Aspect:Double; FullPath,Key:string; Lock:THandle;
begin
  Ready(V,S);
  if (FView=nil) or (FViewport<>V) or (FSession<>S) then raise Exception.Create('Photo comparison: apply a view to this scene first');
  if TFramesPerSecond.RenderFrameId<=FFrame+1 then raise Exception.Create('Photo comparison: waiting for rendered frames');
  if S.Map.PendingTileWork<>0 then raise Exception.Create('Photo comparison: map is still preparing tiles');
  V.Camera.GetWorldView(P,D,U); Rect:=FrameRect(V);
  if ((P-FPosition).Length>0.002) or ((D-FDirection).Length>0.00001) or ((U-FUp).Length>0.00001) or
    (V.Camera.Perspective.FieldOfViewAxis<>faVertical) or (Abs(V.Camera.Perspective.FieldOfView-FAppliedFov)>0.00001) or
    (Rect.Width<>FRect.Width) or (Rect.Height<>FRect.Height) or (Rect.Left<>FRect.Left) or (Rect.Bottom<>FRect.Bottom) then
    raise Exception.Create('Photo comparison: camera or viewport changed; reapply the saved view');
  if (Width<64) or (Width>4096) then raise Exception.Create('Photo comparison: width must be 64..4096');
  Aspect:=TJSONObject(FView.Find('camera')).Get('aspect_ratio',1.0); Height:=Round(Width/Aspect);
  if (Height<16) or (Height>4096) or (Width>FCrop.Width) or (Height>FCrop.Height) then
    raise Exception.Create('Photo comparison: requested image exceeds the native crop; reduce width or enlarge the viewport');
  FullPath:=ExpandFileName(Path);
  if LowerCase(ExtractFileExt(FullPath))<>'.png' then raise Exception.Create('Photo comparison: output must be PNG');
  ForceDirectories(ExtractFilePath(FullPath));
  Lock:=KnowledgeAcquireWriter(FullPath+'.lock');
  try
  if FileExists(FullPath) or FileExists(FullPath+'.json') then raise Exception.Create('Photo comparison: choose a new filename to preserve previous captures');
  Meta:=TJSONObject.Create(['schema_version',1,'view',FView.Clone,'width',Width,'height',Height,
    'native_width',FCrop.Width,'native_height',FCrop.Height,'generator_hash',S.GenHash,'recipe_hash',S.Map.KnowledgeRecipeHash,
    'render_frame',Int64(TFramesPerSecond.RenderFrameId),'dynamic_scene',True,
    'comparison_scope','Camera and framing are repeatable. Lighting, season, wind, overlays and moving objects must be reviewed separately.']);
  Img:=nil;
  try
    Key:=TJSONObject(FView.Find('camera')).AsJSON+'|'+TJSONObject(FView.Find('image')).AsJSON+'|'+IntToStr(Width)+'x'+IntToStr(Height);
    Meta.Add('framing_hash',MD5Print(MD5String(Key)));
    Img:=V.Container.SaveScreen(FCrop); if (Img.Width<>Cardinal(Width)) or (Img.Height<>Cardinal(Height)) then Img.Resize(Width,Height,riBilinear);
    SaveImage(Img,FullPath); KnowledgeAtomicText(FullPath+'.json',Meta.FormatJSON([],2));
    Result:=TJSONObject.Create(['saved',True,'path',FullPath,'metadata_path',FullPath+'.json','width',Width,'height',Height,'framing_hash',Meta.Get('framing_hash','')]);
  finally Img.Free; Meta.Free end;
  finally KnowledgeReleaseWriter(Lock) end;
end;

function TPhotoViewRender.Restore(V:TCastleViewport; S:TOsm3dStreamingSession):TJSONObject;
begin
  Ready(V,S);
  if FRemembered and (FViewport=V) and (FSession=S) then begin
    V.Camera.SetWorldView(FSavedPosition,FSavedDirection,FSavedUp);
    V.Camera.Perspective.FieldOfView:=FSavedFov; V.Camera.Perspective.FieldOfViewAxis:=FSavedAxis;
    Result:=TJSONObject.Create(['restored',True]);
  end else Result:=TJSONObject.Create(['restored',False]);
  Reset;
end;
end.
