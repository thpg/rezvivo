unit McpPhotoViewTools;
{$mode objfpc}{$H+}
interface
uses CastleViewport, Osm3dStreamingLauncher, Osm3dPhotoViewRender;
type
  TPhotoViewContext = procedure(out Viewport:TCastleViewport; out Session:TOsm3dStreamingSession);
  TPhotoViewMode = procedure(EnterComparison:Boolean);
procedure RegisterPhotoViewRenderTools(Context:TPhotoViewContext; Mode:TPhotoViewMode;
  SharedRenderer:TPhotoViewRender=nil);
procedure ResetPhotoViewRenderTools;
procedure ShutdownPhotoViewRenderTools;
implementation
uses SysUtils, fpjson, McpRegistry, Osm3dPhotoView;
var Renderer:TPhotoViewRender; OwnRenderer:Boolean; GetContext:TPhotoViewContext; SetMode:TPhotoViewMode;
procedure Merge(Dest,Source:TJSONObject);
var I:Integer;
begin try for I:=0 to Source.Count-1 do Dest.Add(Source.Names[I],Source.Items[I].Clone) finally Source.Free end end;
procedure Sample(const P:TJSONObject; R:TJSONObject);
var V:TCastleViewport; S:TOsm3dStreamingSession;
begin GetContext(V,S); Merge(R,Renderer.Sample(V,S)) end;
procedure Apply(const P:TJSONObject; R:TJSONObject);
var V:TCastleViewport; S:TOsm3dStreamingSession; View:TJSONObject; WasActive:Boolean;
begin
  if not (P.Find('view') is TJSONObject) then raise Exception.Create('view must be an object');
  View:=TJSONObject(P.Find('view')); ValidatePhotoView(View); GetContext(V,S);
  if (S=nil) or (V=nil) then raise Exception.Create('Photo comparison requires a real 3D map');
  if S.Map=nil then raise Exception.Create('Photo comparison requires a prepared real map');
  if Abs(TJSONObject(View.Find('camera')).Get('scale_latitude_deg',0.0)-S.Map.WorldScaleLatitude)>0.00001 then
    raise Exception.Create('Photo comparison: map projection scale differs from the saved view');
  WasActive:=Renderer.Active;
  if Assigned(SetMode) then SetMode(True);
  try Merge(R,Renderer.Apply(View,V,S));
  except if not WasActive and Assigned(SetMode) then SetMode(False); raise end;
end;
procedure Capture(const P:TJSONObject; R:TJSONObject);
var V:TCastleViewport; S:TOsm3dStreamingSession;
begin
  GetContext(V,S);
  if P.Get('path','')='' then raise Exception.Create('capture path required');
  Merge(R,Renderer.Capture(P.Get('path',''),P.Get('width',640),V,S));
end;
procedure Restore(const P:TJSONObject; R:TJSONObject);
var V:TCastleViewport; S:TOsm3dStreamingSession;
begin
  GetContext(V,S); Merge(R,Renderer.Restore(V,S)); if Assigned(SetMode) then SetMode(False);
end;
procedure RegisterPhotoViewRenderTools(Context:TPhotoViewContext; Mode:TPhotoViewMode;
  SharedRenderer:TPhotoViewRender);
begin
  if Renderer<>nil then Exit; GetContext:=Context; SetMode:=Mode;
  Renderer:=SharedRenderer; OwnRenderer:=Renderer=nil;
  if OwnRenderer then Renderer:=TPhotoViewRender.Create;
  RegisterMcpCommand('photo_view.sample','Current real-map camera in geographic coordinates, with ground-relative height when available. No saving.','',@Sample);
  RegisterMcpCommand('photo_view.apply','Apply a validated saved photo view to the existing real 3D map. Uses free camera. Does not change the knowledge file or geometry.',
    '{"type":"object","required":["view"],"properties":{"view":{"type":"object"}}}',@Apply);
  RegisterMcpCommand('photo_view.capture','Capture the applied view at matching aspect, plus camera/scene metadata. Rejects a moved camera, resized viewport, pending tiles, stale frame or existing file.',
    '{"type":"object","required":["path"],"properties":{"path":{"type":"string"},"width":{"type":"integer"}}}',@Capture);
  RegisterMcpCommand('photo_view.restore','Restore the camera and lens from before the comparison.','',@Restore);
end;
procedure ShutdownPhotoViewRenderTools;
begin
  if OwnRenderer then Renderer.Free;
  Renderer:=nil; OwnRenderer:=False; GetContext:=nil; SetMode:=nil;
end;
procedure ResetPhotoViewRenderTools;
begin
  { A camera lease belongs to one scene. Do not dereference the old viewport
    while the host tears it down, and do not restore its pose in a new ride. }
  if Renderer=nil then Exit;
  Renderer.Reset;
end;
end.
