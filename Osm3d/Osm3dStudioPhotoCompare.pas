unit Osm3dStudioPhotoCompare;
{$mode objfpc}{$H+}{$codepage UTF8}

{ Photo evidence from the current tile, using the same knowledge store, HTTP
  cache and camera renderer as MCP. Only one world viewport is rendered. }
interface
uses Classes, SysUtils, Math, Types, fpjson, Controls, Forms, StdCtrls, ExtCtrls,
  Graphics, CastleControl, CastleViewport, Osm3dStreamingLauncher,
  Osm3dPhotoViewRender, Osm3dPhotoJobs;
type
  TPhotoImageJob=class(TThread)
  private
    FCacheRoot,FKey:string;
  protected
    procedure Execute; override;
  public
    Data:TBytes;
    Error:string;
    Index:Integer;
    constructor Create(const CacheRoot,Key:string; PhotoIndex:Integer);
    destructor Destroy; override;
  end;
  TComparisonPhoto=record
    SourceId:string;
    Source,View:TJSONObject; { owned by FDocument or FRelatedViews }
    Thumb:TBitmap;
    Attempted:Boolean;
    Error:string;
  end;
  TStudioPhotoCompare=class(TPanel)
  private
    FHost:TCastleControl;
    FRenderer:TPhotoViewRender;
    FViewport:TCastleViewport;
    FSession:TOsm3dStreamingSession;
    FRequest,FDocument,FEvidenceReport:TJSONObject;
    FCacheRoot,FHash,FProviderNotice,FAcquisitionNotice,FKeepSelected:string;
    FProviderReports,FRelatedViews:TJSONArray;
    FPhotos:array of TComparisonPhoto;
    FSelected,FMainIndex,FFailedIndex:Integer;
    FBitmap:TBitmap;
    FHeader:TPanel;
    FTitle,FStatus,FCredit,FSummary:TLabel;
    FSave,FReset,FSource,FClose,FDownload,FDownloadAll,FSequence,FCancel,FReject:TButton;
    FShowRejected:TCheckBox;
    FPhotoArea:TPaintBox;
    FGallery:TPanel;
    FGalleryScroll:TScrollBar;
    FStrip:TPaintBox;
    FTimer:TTimer;
    FJob:TPhotoApiJob;
    FImageJob:TPhotoImageJob;
    FRetiredJobs:TList;
    FThumbOrder:TList;
    FWriting,FChanging,FReapply,FApplied,FAcquiring,FClosePending,FCancelRequested,FShuttingDown:Boolean;
    FAspect:Double;
    FDragX,FDragScroll:Integer;
    FDragging:Boolean;
    FOnClosed:TNotifyEvent;
    procedure Tick(Sender:TObject);
    procedure LayoutChanged(Sender:TObject);
    procedure PaintPhoto(Sender:TObject);
    procedure PaintStrip(Sender:TObject);
    procedure UpdateGalleryScroll;
    procedure SetGalleryOffset(Value:Integer);
    procedure GalleryScrolled(Sender:TObject);
    procedure StripDown(Sender:TObject; Button:TMouseButton; Shift:TShiftState; X,Y:Integer);
    procedure StripMove(Sender:TObject; Shift:TShiftState; X,Y:Integer);
    procedure StripUp(Sender:TObject; Button:TMouseButton; Shift:TShiftState; X,Y:Integer);
    procedure Wheel(Sender:TObject; Shift:TShiftState; WheelDelta:Integer; MousePos:TPoint; var Handled:Boolean);
    procedure CloseClick(Sender:TObject);
    procedure ResetClick(Sender:TObject);
    procedure SaveClick(Sender:TObject);
    procedure SourceClick(Sender:TObject);
    procedure DownloadClick(Sender:TObject);
    procedure DownloadAllClick(Sender:TObject);
    procedure SequenceClick(Sender:TObject);
    procedure CancelClick(Sender:TObject);
    procedure ReviewClick(Sender:TObject);
    procedure ShowRejectedClick(Sender:TObject);
    procedure StartAcquisition(Sequence:Boolean; AllPhotos:Boolean=False);
    procedure StartPhotoReview(const Status,Note:string; View:TJSONObject=nil);
    procedure StartGalleryRead;
    procedure AcquisitionFinished;
    procedure ReleaseFinishedJobs;
    procedure ClearPhotos;
    procedure ReadFinished;
    procedure ImageFinished;
    procedure ScheduleImage;
    procedure SetStatus(const S:string);
    procedure UpdateStatus;
    procedure ApplySelected;
    function CroppedAspect:Double;
    function ImageRect(W,H:Integer):TRect;
    function SourceLabel(Index:Integer):string;
  public
    constructor CreateForHost(AOwner:TComponent; Host:TCastleControl; Renderer:TPhotoViewRender);
    destructor Destroy; override;
    procedure OpenAt(const CacheRoot:string; Request:TJSONObject; V:TCastleViewport; S:TOsm3dStreamingSession);
    procedure CloseComparison;
    procedure Arrange;
    procedure SelectPhoto(Index:Integer);
    procedure SaveCurrentView;
    procedure ResetView;
    function Snapshot:TJSONObject;
    property OnClosed:TNotifyEvent read FOnClosed write FOnClosed;
  end;
implementation
uses LCLIntf, WSControls, FPReadJPEG, FPReadPNG, UiTranslations, Osm3dCache, Osm3dPhotoStatusText,
  Osm3dCacheHTTPFetcher, Osm3dPhotoApi, Osm3dPhotoSources, Osm3dPhotoView,
  Osm3dTileKnowledge,Osm3dPhotoGallery,Osm3dVideoApi,Osm3dVideoSources,
  Osm3dGeoMath,CastleVectors;
const ThumbWidth=156; GalleryHeight=140;

constructor TPhotoImageJob.Create(const CacheRoot,Key:string; PhotoIndex:Integer);
begin
  inherited Create(True);FreeOnTerminate:=False;
  FCacheRoot:=CacheRoot;FKey:=Key;Index:=PhotoIndex;
end;
destructor TPhotoImageJob.Destroy;
begin Terminate;if not Suspended then WaitFor;inherited end;
procedure TPhotoImageJob.Execute;
var Client:TPhotoApiClient; R:TFetchResult;
begin
  Client:=nil;
  try
    if Pos('video-api/v1/frame/',FKey)=1 then
      Client:=TVideoApiClient.Create(TFileSystemCache.Create(FCacheRoot),True,DefaultPhotoApiConfig,DefaultVideoSourceConfig)
    else Client:=TPhotoApiClient.Create(TFileSystemCache.Create(FCacheRoot),True,DefaultPhotoApiConfig);
    R:=Client.ReadImage(FKey);
    if not R.Success then Error:='Photo is not in the HTTP cache'
    else if Length(R.Data)=0 then Error:='Photo is not in the HTTP cache'
    else if Length(R.Data)>8*1024*1024 then Error:='Photo preview is too large'
    else Data:=R.Data;
  except on E:Exception do Error:=E.Message end;
  Client.Free;
end;

constructor TStudioPhotoCompare.CreateForHost(AOwner:TComponent; Host:TCastleControl; Renderer:TPhotoViewRender);
  function Button(const Name,Caption:string; Handler:TNotifyEvent):TButton;
  begin
    Result:=TButton.Create(Self);Result.Parent:=FHeader;Result.Name:=Name;
    BindUiText(Result,Caption);Result.OnClick:=Handler;
  end;
begin
  inherited Create(AOwner);Name:='PhotoComparison';Visible:=False;BevelOuter:=bvNone;
  Color:=clBlack;ParentColor:=False;FHost:=Host;FRenderer:=Renderer;
  FSelected:=-1;FMainIndex:=-1;FFailedIndex:=-1;FAspect:=4/3;
  FBitmap:=TBitmap.Create;
  FRetiredJobs:=TList.Create;
  FThumbOrder:=TList.Create;
  FHeader:=TPanel.Create(Self);FHeader.Parent:=Self;FHeader.BevelOuter:=bvNone;
  FHeader.Color:=clBtnFace;
  FTitle:=TLabel.Create(Self);FTitle.Parent:=FHeader;FTitle.AutoSize:=False;
  FTitle.Font.Style:=[fsBold];FTitle.ShowHint:=True;
  FStatus:=TLabel.Create(Self);FStatus.Parent:=FHeader;FStatus.AutoSize:=False;FStatus.ShowHint:=True;
  FStatus.WordWrap:=True;
  FSummary:=TLabel.Create(Self);FSummary.Parent:=FHeader;FSummary.AutoSize:=False;FSummary.ShowHint:=True;
  FCredit:=TLabel.Create(Self);FCredit.Parent:=FHeader;FCredit.AutoSize:=False;FCredit.ShowHint:=True;
  FReset:=Button('PhotoResetView','Restore photo view',@ResetClick);
  FSave:=Button('PhotoSaveView','Save current view',@SaveClick);
  FSource:=Button('PhotoOpenSource','Open source',@SourceClick);
  FClose:=Button('PhotoClose','Close comparison',@CloseClick);
  FDownload:=Button('PhotoDownloadTile','Load nearby photos',@DownloadClick);
  FDownload.ShowHint:=True;FDownload.Hint:=UiText('Download up to 24 Mapillary photos nearest where comparison was opened. Repeat for the next batch.');
  FDownloadAll:=Button('PhotoDownloadAll','Load tile photos',@DownloadAllClick);
  FDownloadAll.ShowHint:=True;FDownloadAll.Hint:=UiText('Find and download all eligible photos in this tile. Cached images are reused; incomplete searches and failures are reported.');
  FSequence:=Button('PhotoDownloadSequence','Sequence frames',@SequenceClick);
  FSequence.ShowHint:=True;FSequence.Hint:=UiText('Download five preceding and five following frames of the selected Mapillary photo.');
  FCancel:=Button('PhotoCancelDownload','Cancel download',@CancelClick);FCancel.Visible:=False;
  FReject:=Button('PhotoReview','Exclude photo',@ReviewClick);
  FShowRejected:=TCheckBox.Create(Self);FShowRejected.Parent:=FHeader;FShowRejected.Name:='PhotoShowRejected';
  BindUiText(FShowRejected,'Show rejected');FShowRejected.OnClick:=@ShowRejectedClick;
  FPhotoArea:=TPaintBox.Create(Self);FPhotoArea.Parent:=Self;FPhotoArea.OnPaint:=@PaintPhoto;
  FGallery:=TPanel.Create(Self);FGallery.Parent:=Self;FGallery.BevelOuter:=bvNone;
  FGallery.Color:=RGBToColor(30,34,38);FGallery.ParentColor:=False;
  FGallery.OnMouseWheel:=@Wheel;
  FGalleryScroll:=TScrollBar.Create(Self);FGalleryScroll.Parent:=FGallery;
  FGalleryScroll.Name:='PhotoGalleryScroll';FGalleryScroll.Kind:=sbHorizontal;
  FGalleryScroll.SmallChange:=ThumbWidth;FGalleryScroll.OnChange:=@GalleryScrolled;
  FStrip:=TPaintBox.Create(Self);FStrip.Parent:=FGallery;FStrip.OnPaint:=@PaintStrip;
  FStrip.OnMouseDown:=@StripDown;FStrip.OnMouseMove:=@StripMove;FStrip.OnMouseUp:=@StripUp;FStrip.OnMouseWheel:=@Wheel;
  FTimer:=TTimer.Create(Self);FTimer.Interval:=60;FTimer.Enabled:=False;FTimer.OnTimer:=@Tick;
  OnResize:=@LayoutChanged;
end;
destructor TStudioPhotoCompare.Destroy;
var I:Integer;
begin
  FShuttingDown:=True;OnClosed:=nil;CloseComparison;
  for I:=0 to FRetiredJobs.Count-1 do TObject(FRetiredJobs[I]).Free;
  FRetiredJobs.Free;ClearPhotos;FThumbOrder.Free;FBitmap.Free;inherited;
end;
procedure TStudioPhotoCompare.ClearPhotos;
var I:Integer;
begin
  for I:=0 to High(FPhotos) do FPhotos[I].Thumb.Free;
  FThumbOrder.Clear;
  FPhotos:=nil;FreeAndNil(FDocument);FreeAndNil(FProviderReports);FreeAndNil(FRelatedViews);FreeAndNil(FEvidenceReport);
  FProviderNotice:='';FBitmap.Clear;
  FSelected:=-1;FMainIndex:=-1;FFailedIndex:=-1;
end;
procedure TStudioPhotoCompare.OpenAt(const CacheRoot:string; Request:TJSONObject; V:TCastleViewport; S:TOsm3dStreamingSession);
var R:TJSONObject; HostBounds:TRect;
begin
  CloseComparison;
  if FClosePending then Exit;
  FCacheRoot:=CacheRoot;FRequest:=TJSONObject(Request.Clone);FViewport:=V;FSession:=S;
  FAcquisitionNotice:='';FKeepSelected:='';
  FRenderer.Reset;FRenderer.Remember(V,S);
  HostBounds:=FHost.BoundsRect;
  FHost.Align:=alNone;Parent:=FHost.Parent;Align:=alClient;
  HandleNeeded;FGallery.HandleNeeded;Visible:=True;
  SetBounds(HostBounds.Left,HostBounds.Top,HostBounds.Right-HostBounds.Left,HostBounds.Bottom-HostBounds.Top);
  BringToFront;FHost.BringToFront;Arrange;
  FTitle.Caption:=UiText('Photo and 3D');SetStatus(UiText('Loading tile photos…'));FCredit.Caption:='';
  StartGalleryRead;
  FWriting:=False;UpdateStatus;FTimer.Enabled:=True;
end;
procedure TStudioPhotoCompare.CloseComparison;
var R:TJSONObject; WasOpen:Boolean;
begin
  FClosePending:=False;FAcquiring:=False;FCancel.Visible:=False;
  WasOpen:=Visible;FTimer.Enabled:=False;
  { Workers own cloned JSON/cache keys, never viewport/session pointers.
    Detach them before a streaming restart can destroy the borrowed scene.
    No network WaitFor occurs in this close handler. }
  if FJob<>nil then begin FJob.Cancel;FRetiredJobs.Add(FJob);FJob:=nil end;
  if FImageJob<>nil then begin FImageJob.Terminate;FRetiredJobs.Add(FImageJob);FImageJob:=nil end;
  if WasOpen and (FViewport<>nil) and (FSession<>nil) then begin
    R:=FRenderer.Restore(FViewport,FSession);R.Free;
  end;
  if WasOpen then begin
    FHost.SetBounds(Left,Top,Width,Height);
    if FHost.HandleAllocated then
      TWSWinControlClass(FHost.WidgetSetClass).SetBounds(FHost,Left,Top,Width,Height);
  end;
  Visible:=False;FViewport:=nil;FSession:=nil;FApplied:=False;FReapply:=False;
  if FDragging then begin FDragging:=False;SetCaptureControl(nil) end;
  FHost.Align:=alClient;ClearPhotos;FreeAndNil(FRequest);
  ReleaseFinishedJobs;
  FTimer.Enabled:=(FRetiredJobs.Count>0) and not FShuttingDown;
  if WasOpen and Assigned(FOnClosed) then FOnClosed(Self);
end;
procedure TStudioPhotoCompare.ReleaseFinishedJobs;
var I:Integer;
begin
  for I:=FRetiredJobs.Count-1 downto 0 do
    if TThread(FRetiredJobs[I]).Finished then begin
      TObject(FRetiredJobs[I]).Free;FRetiredJobs.Delete(I);
    end;
end;
procedure TStudioPhotoCompare.CloseClick(Sender:TObject);
begin CloseComparison end;
procedure TStudioPhotoCompare.SetStatus(const S:string);
begin FStatus.Caption:=S;FStatus.Hint:=S end;
function TStudioPhotoCompare.SourceLabel(Index:Integer):string;
var S:string;
begin
  if FPhotos[Index].Source.Get('sequence_id','')<>'' then
    Exit(FPhotos[Index].Source.Get('provider','')+' '+FPhotos[Index].Source.Get('sequence_id','')+
      ' / '+FPhotos[Index].Source.Get('media_id',''));
  if FPhotos[Index].View<>nil then Exit(FPhotos[Index].View.Get('label',''));
  S:=FPhotos[Index].Source.Get('source_url','');
  S:=Copy(S,LastDelimiter('/',S)+1,MaxInt);S:=StringReplace(S,'_',' ',[rfReplaceAll]);
  if S='' then S:=FPhotos[Index].Source.Get('id','');Result:=S;
end;
procedure TStudioPhotoCompare.UpdateStatus;
var V:TJSONObject;
begin
  FDownload.Enabled:=(FJob=nil) and (FRetiredJobs.Count=0);
  FDownloadAll.Enabled:=FDownload.Enabled;
  FShowRejected.Enabled:=FJob=nil;
  FReject.Enabled:=(FSelected>=0) and (FJob=nil);
  if (FSelected>=0) and not IsComparisonSource(FPhotos[FSelected].Source) then
    BindUiText(FReject,'Restore photo') else BindUiText(FReject,'Exclude photo');
  FSequence.Enabled:=(FJob=nil) and (FRetiredJobs.Count=0) and (FSelected>=0) and
    (FPhotos[FSelected].Source.Get('provider','')='mapillary') and
    (FPhotos[FSelected].Source.Get('sequence_id','')<>'');
  FReset.Enabled:=(FSelected>=0) and ((FPhotos[FSelected].View<>nil) or
    (FPhotos[FSelected].Source.Find('latitude')<>nil));
  FSave.Enabled:=(FSelected>=0) and (FMainIndex=FSelected) and (FJob=nil);
  FSource.Enabled:=FSelected>=0;
  if FSelected<0 then Exit;
  V:=FPhotos[FSelected].View;
  if not IsComparisonSource(FPhotos[FSelected].Source) then
    SetStatus(UiText('Rejected')+': '+FPhotos[FSelected].Source.Get('review_note',''))
  else if FPhotos[FSelected].Error<>'' then SetStatus(UiText(FPhotos[FSelected].Error))
  else if (V=nil) and (FPhotos[FSelected].Source.Find('latitude')<>nil) then
    SetStatus(UiText('Approximate view from photo coordinates'))
  else if V=nil then SetStatus(UiText('No saved view — position the 3D camera and save it'))
  else if V.Get('status','draft')='draft' then SetStatus(UiText('Overview of the photographed place'))
  else SetStatus(UiText('Saved photo view'));
  if FProviderNotice<>'' then SetStatus(FStatus.Caption+' — '+FProviderNotice);
  if FAcquisitionNotice<>'' then SetStatus(FStatus.Caption+' — '+FAcquisitionNotice);
end;

procedure TStudioPhotoCompare.StartGalleryRead;
var Request:TJSONObject;
begin
  Request:=TJSONObject(FRequest.Clone);
  try
    Request.Strings['media_type']:='knowledge';Request.Strings['action']:='gallery';
    FJob:=TPhotoApiJob.Create(FCacheRoot,DefaultPhotoApiConfig,Request);FJob.Start;
  finally Request.Free end;
end;

procedure TStudioPhotoCompare.StartAcquisition(Sequence:Boolean; AllPhotos:Boolean);
var Request,Photo:TJSONObject;
begin
  if (FJob<>nil) or (FRetiredJobs.Count>0) then Exit;
  if Sequence and ((FSelected<0) or (FPhotos[FSelected].Source.Get('provider','')<>'mapillary') or
    (FPhotos[FSelected].Source.Get('sequence_id','')='')) then Exit;
  Request:=TJSONObject(FRequest.Clone);Photo:=nil;
  try
    { FRequest stores the actual camera position when comparison was opened.
      Replaying an old photo must not silently move this acquisition focus. }
    Request.Strings['action']:='acquire';Request.Integers['max_downloads']:=24;
    if AllPhotos then begin
      Request.Strings['mode']:='all';Request.Strings['providers']:='all';Request.Delete('max_downloads');
      Request.Integers['max_pages']:=500;Request.Integers['max_candidates']:=50000;
    end;
    Request.Integers['before']:=5;Request.Integers['after']:=5;
    if Sequence then begin
      Photo:=TJSONObject(FPhotos[FSelected].Source.Clone);
      Photo.Strings['image_id']:=Photo.Get('media_id','');
    end;
    FKeepSelected:='';if Sequence and (FSelected>=0) then FKeepSelected:=FPhotos[FSelected].SourceId;
    FAcquisitionNotice:='';FJob:=TPhotoApiJob.Create(FCacheRoot,DefaultPhotoApiConfig,Request,Photo);
    FAcquiring:=True;FCancelRequested:=False;FWriting:=False;FCancel.Visible:=True;
    { This button starts hidden. Create its native handle also in a hidden
      Studio test window, where showing the parent cannot create it for us. }
    FCancel.HandleNeeded;FJob.Start;
    UpdateStatus;
    if AllPhotos then SetStatus(UiText('Finding all tile photos…'))
    else SetStatus(UiText('Finding nearby Mapillary photos…'));
    Arrange;
  finally Photo.Free;Request.Free end;
end;

procedure TStudioPhotoCompare.DownloadClick(Sender:TObject);
begin try StartAcquisition(False) except on E:Exception do SetStatus(E.Message) end end;
procedure TStudioPhotoCompare.DownloadAllClick(Sender:TObject);
begin try StartAcquisition(False,True) except on E:Exception do SetStatus(E.Message) end end;
procedure TStudioPhotoCompare.SequenceClick(Sender:TObject);
begin try StartAcquisition(True) except on E:Exception do SetStatus(E.Message) end end;
procedure TStudioPhotoCompare.CancelClick(Sender:TObject);
begin if FAcquiring and (FJob<>nil) then begin FCancelRequested:=True;FJob.Cancel;SetStatus(UiText('Cancelling photo download…')) end end;

procedure TStudioPhotoCompare.StartPhotoReview(const Status,Note:string; View:TJSONObject);
var Request:TJSONObject;
begin
  if (FSelected<0) or (FJob<>nil) then Exit;
  Request:=TJSONObject(FRequest.Clone);
  try
    Request.Strings['media_type']:='knowledge';Request.Strings['action']:='review_photo';
    Request.Add('source',FPhotos[FSelected].Source.Clone);
    if Status<>'' then begin Request.Add('review_status',Status);Request.Add('review_note',Note) end;
    if View<>nil then Request.Add('view',View.Clone);
    Request.Add('expected_revision',FDocument.Get('revision',0));Request.Add('expected_hash',FHash);
    Request.Add('author','OSM3D Studio');Request.Add('change_note','Photo evidence review or camera update');
    FKeepSelected:=FPhotos[FSelected].SourceId;
    FJob:=TPhotoApiJob.Create(FCacheRoot,DefaultPhotoApiConfig,Request);FWriting:=True;FJob.Start;
    UpdateStatus;SetStatus(UiText('Saving photo review…'));
  finally Request.Free end;
end;

procedure TStudioPhotoCompare.ReviewClick(Sender:TObject);
begin
  if FSelected<0 then Exit;
  try
    if IsComparisonSource(FPhotos[FSelected].Source) then
      StartPhotoReview('rejected','Does not provide information about this place')
    else StartPhotoReview('accepted','Manually restored as a useful reference for this place');
  except on E:Exception do SetStatus(E.Message) end;
end;

procedure TStudioPhotoCompare.ShowRejectedClick(Sender:TObject);
begin
  if FJob<>nil then Exit;
  if FSelected>=0 then FKeepSelected:=FPhotos[FSelected].SourceId;
  StartGalleryRead;UpdateStatus;
end;

procedure TStudioPhotoCompare.AcquisitionFinished;
var R:TJSONObject;State,Detail:string;Failures:TJSONArray;I:Integer;
begin
  R:=FJob.ResultPage(0,100);
  try
    State:=R.Get('status','');Detail:='';
    if State='credentials_required' then Detail:=UiText('API token is not configured')
    else if State='access_denied' then Detail:=UiText('Photo access is unavailable; check the token permissions')
    else if State='request_rejected' then Detail:=UiText('The photo provider rejected the request')
    else if State='rate_limited' then Detail:=UiText('Photo provider rate limit reached; try again later')
    else if State='cancelled' then Detail:=UiText('Photo download cancelled')
    else if R.Get('discovery_incomplete',False) or
      ((R.Find('discovery_complete')<>nil) and not R.Get('discovery_complete',True)) then
      Detail:=UiText('Photo search is incomplete');
    FAcquisitionNotice:=Format(UiText('Loaded: %d; already cached: %d; remaining candidates: %d'),
      [R.Get('downloaded_count',0),R.Get('cached_count',0),R.Get('remaining_count',0)]);
    if R.Get('failed_count',0)>0 then FAcquisitionNotice:=FAcquisitionNotice+'; '+
      Format(UiText('Failed photos: %d'),[R.Get('failed_count',0)]);
    if R.Get('excluded_count',0)>0 then FAcquisitionNotice:=FAcquisitionNotice+'; '+
      Format(UiText('Excluded photos: %d'),[R.Get('excluded_count',0)]);
    Failures:=ArrayAt(R,'provider_failures');
    if (Failures<>nil) and (Failures.Count>0) then begin
      if State='cancelled' then Detail:=UiText('Photo download cancelled')+'; '
      else Detail:='';
      Detail:=Detail+UiText('Unavailable providers')+': ';
      for I:=0 to Failures.Count-1 do begin
        if I>0 then Detail:=Detail+', ';
        Detail:=Detail+PhotoJsonString(Failures[I],'provider')+' ('+
          PhotoJsonString(Failures[I],'status')+')';
      end;
    end;
    if Detail<>'' then FAcquisitionNotice:=FAcquisitionNotice+' — '+Detail;
  finally R.Free end;
end;
procedure TStudioPhotoCompare.ReadFinished;
var R:TJSONObject; Sources,Views:TJSONArray; I,J,N,Best:Integer; V:TJSONObject;
    CamLat,CamLon,Distance,BestDistance:Double; Sample:TJSONObject;Order:TStringList;SortKey:string;
    Sorted:array of TComparisonPhoto;
begin
  R:=FJob.ResultPage(0,100);
  try
    ClearPhotos;FDocument:=TJSONObject(R.Find('document').Clone);FHash:=R.Get('content_hash','');
    if R.Find('evidence_report') is TJSONObject then FEvidenceReport:=TJSONObject(R.Find('evidence_report').Clone);
    if (FEvidenceReport<>nil) and (FEvidenceReport.Find('counts') is TJSONObject) then begin
      V:=TJSONObject(FEvidenceReport.Find('counts'));
      FSummary.Caption:=Format(UiText('Found: %d | Cached: %d | Rejected: %d | Awaiting review: %d | Used: %d'),
        [V.Get('discovered',0),V.Get('downloaded',0),V.Get('rejected',0),V.Get('unreviewed',0),V.Get('used',0)]);
      if FEvidenceReport.Find('coverage') is TJSONObject then begin
        V:=TJSONObject(FEvidenceReport.Find('coverage'));
        FSummary.Caption:=FSummary.Caption+LineEnding+Format(UiText('Object-reviewed photos: %d | Details awaiting placement: %d'),
          [V.Get('object_reviewed_images',0),V.Get('deferred_inventory_items',0)]);
      end;
    end else FSummary.Caption:=UiText('Cached photos require review before they can change the tile');
    if R.Find('photo_workflow') is TJSONObject then
      FSummary.Caption:=FSummary.Caption+LineEnding+PhotoWorkflowCaption(TJSONObject(R.Find('photo_workflow')));
    FSummary.Hint:=FSummary.Caption;
    if R.Find('photo_workflow') is TJSONObject then
      FSummary.Hint:=FSummary.Hint+LineEnding+TJSONObject(R.Find('photo_workflow')).Get('reason','');
    if R.Find('related_photo_views') is TJSONArray then
      FRelatedViews:=TJSONArray(R.Find('related_photo_views').Clone);
    if R.Find('photo_providers') is TJSONArray then begin
      FProviderReports:=TJSONArray(R.Find('photo_providers').Clone);
      for I:=0 to FProviderReports.Count-1 do begin
        V:=TJSONObject(FProviderReports[I]);
        if (V.Get('provider','')='mapillary') and (V.Get('status','')<>'complete') then begin
          SortKey:=V.Get('status','unavailable');
          if (SortKey='coverage_only') or (SortKey='coverage_truncated') then
            FProviderNotice:=UiText('Mapillary coverage found — load nearby photos')
          else if (SortKey='access_denied') or (SortKey='metadata_unavailable') then
            FProviderNotice:='Mapillary: '+UiText('Photo access is unavailable; check the token permissions')
          else if SortKey='coverage_empty' then
            FProviderNotice:='Mapillary: '+UiText('No coverage found in this area')
          else if SortKey='cache_miss' then
            FProviderNotice:='Mapillary: '+UiText('No saved photo search for this area')
          else if SortKey<>'credentials_required' then
            FProviderNotice:='Mapillary: '+UiText('Photo search is incomplete');
        end;
        if (V.Get('provider','')='mapillary') and not V.Get('credentials_available',True) then
          FProviderNotice:='Mapillary: '+UiText('API token is not configured');
      end;
    end;
    if R.Get('gallery_omitted_capacity',0)>0 then FProviderNotice:=FProviderNotice+' '+
      Format(UiText('Gallery limit reached: %d additional cached photos'),[R.Get('gallery_omitted_capacity',0)]);
    if FDocument.Find('photo_views')=nil then FDocument.Add('photo_views',TJSONArray.Create);
    Sources:=TJSONArray(FDocument.Find('sources'));Views:=TJSONArray(FDocument.Find('photo_views'));
    for I:=0 to Sources.Count-1 do if IsComparisonSource(TJSONObject(Sources[I]),FShowRejected.Checked) then begin
      N:=Length(FPhotos);SetLength(FPhotos,N+1);FPhotos[N].Source:=TJSONObject(Sources[I]);
      FPhotos[N].SourceId:=FPhotos[N].Source.Get('id','');
      FPhotos[N].View:=FindComparisonView(FDocument,FRelatedViews,FPhotos[N].SourceId);
    end;
    { Bbox discovery order is unspecified. Keep sequence neighbors adjacent and
      chronological; this order does not change the persisted knowledge file. }
    Order:=TStringList.Create;Order.Sorted:=True;Order.Duplicates:=dupAccept;
    try
      for I:=0 to High(FPhotos) do begin
        V:=FPhotos[I].Source;
        if V.Get('sequence_id','')<>'' then SortKey:='0/'+V.Get('provider','')+'/'+V.Get('sequence_id','')+
          '/'+V.Get('captured_at','')+'/'+V.Get('media_id','')
        else SortKey:='1/'+Format('%.8d',[I]);
        Order.AddObject(SortKey,TObject(PtrInt(I)));
      end;
      SetLength(Sorted,Length(FPhotos));
      for I:=0 to Order.Count-1 do Sorted[I]:=FPhotos[PtrInt(Order.Objects[I])];
      FPhotos:=Sorted;
    finally Order.Free end;
    UpdateGalleryScroll;SetGalleryOffset(0);
    if Length(FPhotos)=0 then begin
      SetStatus(UiText('This tile has no saved source photos')+' '+FProviderNotice+' '+FAcquisitionNotice);UpdateStatus;Exit;
    end;
    Best:=0;BestDistance:=1e30;Sample:=FRenderer.Sample(FViewport,FSession);
    try
      CamLat:=FRequest.Get('latitude',TJSONObject(Sample.Find('camera')).Get('latitude',0.0));
      CamLon:=FRequest.Get('longitude',TJSONObject(Sample.Find('camera')).Get('longitude',0.0));
      for I:=0 to High(FPhotos) do begin
        V:=nil;
        if (FPhotos[I].Source.Get('coordinate_role','')='camera') and (FPhotos[I].Source.Find('latitude')<>nil) then
          V:=FPhotos[I].Source
        else if FPhotos[I].View<>nil then V:=TJSONObject(FPhotos[I].View.Find('camera'));
        if V=nil then Continue;
        Distance:=Sqr(V.Get('latitude',0.0)-CamLat)+Sqr((V.Get('longitude',0.0)-CamLon)*Cos(DegToRad(CamLat)));
        if Distance<BestDistance then begin BestDistance:=Distance;Best:=I end;
      end;
    finally Sample.Free end;
    if FKeepSelected<>'' then for I:=0 to High(FPhotos) do
      if FPhotos[I].SourceId=FKeepSelected then begin Best:=I;Break end;
    FKeepSelected:='';SelectPhoto(Best);
  finally R.Free end;
end;
function TStudioPhotoCompare.CroppedAspect:Double;
var V,C:TJSONData;
begin
  Result:=4/3;
  if (FMainIndex=FSelected) and (FBitmap.Height>0) then Result:=FBitmap.Width/FBitmap.Height;
  if (FSelected<0) or (FPhotos[FSelected].View=nil) then Exit;
  V:=FPhotos[FSelected].View.Find('image');C:=V.FindPath('crop');
  Result:=V.FindPath('width_px').AsFloat/V.FindPath('height_px').AsFloat;
  if C<>nil then Result:=Result*(C.Items[2].AsFloat-C.Items[0].AsFloat)/(C.Items[3].AsFloat-C.Items[1].AsFloat);
end;
procedure TStudioPhotoCompare.Arrange;
var H,W,AreaH,RightX,VW,VH,TopY,BX,BY:Integer;
  procedure Place(B:TControl;Width96:Integer);
  var BW:Integer;
  begin
    if not B.Visible then Exit;BW:=Scale96ToFont(Width96);
    if (BX>10) and (BX+BW>ClientWidth-10) then begin BX:=10;Inc(BY,32) end;
    B.SetBounds(BX,BY,BW,26);Inc(BX,BW+6);
  end;
begin
  if not Visible or FChanging then Exit;FChanging:=True;
  try
    W:=Max(1,ClientWidth div 2);
    FTitle.SetBounds(10,4,Max(10,ClientWidth-20),20);
    FSummary.SetBounds(10,27,Max(10,ClientWidth-20),60);
    FStatus.SetBounds(10,89,Max(10,ClientWidth-20),36);
    BX:=10;BY:=127;
    Place(FDownloadAll,145);Place(FDownload,165);Place(FSequence,145);Place(FCancel,140);
    Place(FReject,120);Place(FShowRejected,150);
    Place(FReset,160);Place(FSave,155);Place(FSource,105);Place(FClose,140);
    FCredit.SetBounds(10,BY+29,Max(10,ClientWidth-20),18);H:=FCredit.Top+21;
    FHeader.SetBounds(0,0,ClientWidth,H);
    FGallery.SetBounds(0,Max(H,ClientHeight-GalleryHeight),ClientWidth,GalleryHeight);
    FGalleryScroll.SetBounds(0,GalleryHeight-20,FGallery.ClientWidth,20);
    { Only the visible area is a control/GDI canvas. Large galleries live in
      a 32-bit logical scrollbar, never in a multi-million-pixel paintbox. }
    FStrip.SetBounds(0,0,FGallery.ClientWidth,GalleryHeight-20);UpdateGalleryScroll;
    AreaH:=Max(32,FGallery.Top-H);FPhotoArea.SetBounds(0,H,W-3,AreaH);
    FAspect:=CroppedAspect;
    RightX:=W+3;VW:=Max(16,ClientWidth-RightX);VH:=Round(VW/FAspect);
    if VH>AreaH then begin VH:=AreaH;VW:=Round(VH*FAspect) end;
    TopY:=H+(AreaH-VH) div 2;
    FHost.SetBounds(Left+RightX+(ClientWidth-RightX-VW) div 2,Top+TopY,VW,VH);
    if FHost.HandleAllocated then
      TWSWinControlClass(FHost.WidgetSetClass).SetBounds(FHost,FHost.Left,FHost.Top,VW,VH);
    FHost.BringToFront;FPhotoArea.Invalidate;FStrip.Invalidate;
  finally FChanging:=False end;
end;
procedure TStudioPhotoCompare.LayoutChanged(Sender:TObject);
begin Arrange end;
procedure TStudioPhotoCompare.ApplySelected;
var V,R,S,C:TJSONObject;P:TVector3;Y:Single;Lat,Lon,Pitch,CameraHeight,Asp:Double;W,H:Integer;
begin
  if FSelected<0 then Exit;
  if FPhotos[FSelected].View<>nil then V:=TJSONObject(FPhotos[FSelected].View.Clone)
  else begin
    S:=FPhotos[FSelected].Source;if S.Find('latitude')=nil then Exit;
    Lat:=S.Get('latitude',0.0);Lon:=S.Get('longitude',0.0);CameraHeight:=1.8;Pitch:=0;
    if S.Get('coordinate_role','unknown')<>'camera' then begin
      { Object geotags are not calibrated camera positions: show an overview. }
      Lat:=Lat-0.00035;CameraHeight:=30;Pitch:=-35;
    end;
    P:=FSession.GeoToLocal(TLatLon.Make(Lat,Lon));
    if not FSession.Map.GroundYAt(P.X,P.Z,Y) then Y:=0;
    W:=S.Get('width',1600);H:=S.Get('height',1200);if (W<16) or (H<16) then begin W:=1600;H:=1200 end;
    if FMainIndex=FSelected then begin W:=FBitmap.Width;H:=FBitmap.Height end;
    Asp:=W/H;
    C:=TJSONObject.Create(['latitude',Lat,'longitude',Lon,'elevation_m',Y+CameraHeight,
      'scale_latitude_deg',FSession.Map.WorldScaleLatitude,'heading_deg',S.Get('heading_deg',0.0),
      'pitch_deg',Pitch,'roll_deg',0,'vertical_fov_deg',60,'aspect_ratio',Asp]);
    V:=TJSONObject.Create(['id','view:approx:'+S.Get('id',''),'source_id',S.Get('id',''),
      'label',SourceLabel(FSelected),'status','draft','confidence',0.15,
      'note','Approximate geographic overview from source metadata, not a solved photo pose.',
      'camera',C,'image',TJSONObject.Create(['width_px',W,'height_px',H,'projection','perspective',
      'crop',TJSONArray.Create([0,0,1,1])]),'anchors',TJSONArray.Create,'regions',TJSONArray.Create,
      'known_parameters',TJSONArray.Create]);
  end;
  try
    { Geographic position and lens are retained when the current map has a
      different local projection origin/scale. The saved evidence is unchanged. }
    TJSONObject(V.Find('camera')).Floats['scale_latitude_deg']:=FSession.Map.WorldScaleLatitude;
    R:=FRenderer.Apply(V,FViewport,FSession);R.Free;FApplied:=True;
  finally V.Free end;
end;
procedure TStudioPhotoCompare.SelectPhoto(Index:Integer);
begin
  if (Index<0) or (Index>=Length(FPhotos)) then raise ERangeError.Create('Photo index is outside the gallery');
  FSelected:=Index;FMainIndex:=-1;FFailedIndex:=-1;FBitmap.Clear;
  FTitle.Caption:=Format('%d / %d — %s',[Index+1,Length(FPhotos),SourceLabel(Index)]);FTitle.Hint:=FTitle.Caption;
  FCredit.Caption:=FPhotos[Index].Source.Get('author','')+'   '+FPhotos[Index].Source.Get('license','');FCredit.Hint:=FCredit.Caption;
  if Index*ThumbWidth<FGalleryScroll.Position then SetGalleryOffset(Index*ThumbWidth)
  else if (Index+1)*ThumbWidth>FGalleryScroll.Position+FStrip.Width then
    SetGalleryOffset((Index+1)*ThumbWidth-FStrip.Width);
  FRenderer.ClearApplied;FApplied:=False;FReapply:=False;
  Arrange;UpdateStatus;
  if (FPhotos[Index].View<>nil) or (FPhotos[Index].Source.Find('latitude')<>nil) then begin FApplied:=True;FReapply:=True end;
end;
function TStudioPhotoCompare.ImageRect(W,H:Integer):TRect;
var C:TJSONData;
begin
  Result:=Rect(0,0,W,H);
  if (FSelected<0) or (FPhotos[FSelected].View=nil) then Exit;
  C:=FPhotos[FSelected].View.FindPath('image.crop');
  Result:=Rect(Round(W*C.Items[0].AsFloat),Round(H*C.Items[1].AsFloat),
    Round(W*C.Items[2].AsFloat),Round(H*C.Items[3].AsFloat));
end;
procedure TStudioPhotoCompare.PaintPhoto(Sender:TObject);
var Dest,Src:TRect;W,H:Integer;
begin
  with FPhotoArea.Canvas do begin Brush.Color:=clBlack;FillRect(FPhotoArea.ClientRect);Font.Color:=clSilver end;
  if (FMainIndex<>FSelected) or FBitmap.Empty then begin
    FPhotoArea.Canvas.TextOut(12,12,UiText('Select a source photo'));Exit;
  end;
  Src:=ImageRect(FBitmap.Width,FBitmap.Height);
  W:=FPhotoArea.Width;H:=Round(W/FAspect);
  if H>FPhotoArea.Height then begin H:=FPhotoArea.Height;W:=Round(H*FAspect) end;
  Dest:=Rect((FPhotoArea.Width-W) div 2,(FPhotoArea.Height-H) div 2,0,0);
  Dest.Right:=Dest.Left+W;Dest.Bottom:=Dest.Top+H;
  FPhotoArea.Canvas.CopyRect(Dest,FBitmap.Canvas,Src);
end;
procedure TStudioPhotoCompare.PaintStrip(Sender:TObject);
var I,L,R,X,W,H:Integer; B:TBitmap; LabelText:string;
begin
  with FStrip.Canvas do begin Brush.Color:=FGallery.Color;FillRect(FStrip.ClientRect);Font.Color:=clWhite end;
  L:=Max(0,FGalleryScroll.Position div ThumbWidth);
  R:=Min(High(FPhotos),(FGalleryScroll.Position+Max(0,FStrip.Width-1)) div ThumbWidth);
  for I:=L to R do begin
    X:=I*ThumbWidth-FGalleryScroll.Position;B:=FPhotos[I].Thumb;
    if B<>nil then begin
      W:=ThumbWidth-12;H:=Round(W*B.Height/Max(1,B.Width));
      if H>86 then begin H:=86;W:=Round(H*B.Width/Max(1,B.Height)) end;
      FStrip.Canvas.StretchDraw(Rect(X+(ThumbWidth-W) div 2,5+(86-H) div 2,X+(ThumbWidth+W) div 2,5+(86+H) div 2),B);
    end;
    if I=FSelected then begin FStrip.Canvas.Pen.Color:=RGBToColor(48,194,210);FStrip.Canvas.Pen.Width:=3 end
    else begin FStrip.Canvas.Pen.Color:=clGray;FStrip.Canvas.Pen.Width:=1 end;
    FStrip.Canvas.Brush.Style:=bsClear;FStrip.Canvas.Rectangle(X+3,2,X+ThumbWidth-3,94);FStrip.Canvas.Brush.Style:=bsSolid;
    if FPhotos[I].View<>nil then LabelText:=UiText('Saved view') else LabelText:=UiText('No view');
    FStrip.Canvas.TextOut(X+8,98,IntToStr(I+1)+' - '+LabelText);
  end;
end;
procedure TStudioPhotoCompare.UpdateGalleryScroll;
var Page,Total,Offset:Integer;
begin
  Page:=Max(1,FStrip.Width);Total:=Max(Page,Length(FPhotos)*ThumbWidth);
  Offset:=EnsureRange(FGalleryScroll.Position,0,Total-Page);
  FGalleryScroll.SetParams(Offset,0,Total-1,Page);
  FGalleryScroll.LargeChange:=EnsureRange(Page-ThumbWidth,ThumbWidth,32768);
  FGalleryScroll.Enabled:=Total>Page;
end;
procedure TStudioPhotoCompare.SetGalleryOffset(Value:Integer);
begin
  FGalleryScroll.Position:=EnsureRange(Value,0,Max(0,Length(FPhotos)*ThumbWidth-Max(1,FStrip.Width)));
end;
procedure TStudioPhotoCompare.GalleryScrolled(Sender:TObject);
begin FStrip.Invalidate end;
procedure TStudioPhotoCompare.StripDown(Sender:TObject; Button:TMouseButton; Shift:TShiftState; X,Y:Integer);
begin
  if Button<>mbLeft then Exit;FDragging:=True;FDragX:=Mouse.CursorPos.X;FDragScroll:=FGalleryScroll.Position;
  SetCaptureControl(FStrip);
end;
procedure TStudioPhotoCompare.StripMove(Sender:TObject; Shift:TShiftState; X,Y:Integer);
begin if FDragging then SetGalleryOffset(FDragScroll+FDragX-Mouse.CursorPos.X) end;
procedure TStudioPhotoCompare.StripUp(Sender:TObject; Button:TMouseButton; Shift:TShiftState; X,Y:Integer);
begin
  if (Button<>mbLeft) or not FDragging then Exit;FDragging:=False;SetCaptureControl(nil);
  if (Abs(Mouse.CursorPos.X-FDragX)<5) and (X>=0) and (X<FStrip.Width) and
    (Y>=0) and (Y<FStrip.Height) and ((X+FGalleryScroll.Position) div ThumbWidth<Length(FPhotos)) then
    SelectPhoto((X+FGalleryScroll.Position) div ThumbWidth);
end;
procedure TStudioPhotoCompare.Wheel(Sender:TObject; Shift:TShiftState; WheelDelta:Integer; MousePos:TPoint; var Handled:Boolean);
begin SetGalleryOffset(FGalleryScroll.Position-WheelDelta);Handled:=True end;
procedure TStudioPhotoCompare.ScheduleImage;
var I,L,R,N:Integer;
begin
  if (FImageJob<>nil) or (FSelected<0) then Exit;N:=-1;
  if (FMainIndex<>FSelected) and (FFailedIndex<>FSelected) then N:=FSelected
  else begin
    L:=Max(0,FGalleryScroll.Position div ThumbWidth);
    R:=Min(High(FPhotos),(FGalleryScroll.Position+Max(0,FStrip.Width-1)) div ThumbWidth);
    for I:=L to R do if not FPhotos[I].Attempted then begin N:=I;Break end;
  end;
  if N<0 then Exit;
  FImageJob:=TPhotoImageJob.Create(FCacheRoot,FPhotos[N].Source.Get('cache_key',''),N);FImageJob.Start;
end;
procedure TStudioPhotoCompare.ImageFinished;
var P:TPicture;S:TMemoryStream;B:TBitmap;N,W,H,Index,Oldest:Integer;
begin
  N:=FImageJob.Index;if (N<0) or (N>=Length(FPhotos)) then Exit;
  FPhotos[N].Attempted:=True;
  if FImageJob.Error<>'' then begin FPhotos[N].Error:=FImageJob.Error;if N=FSelected then FFailedIndex:=N;UpdateStatus;Exit end;
  S:=TMemoryStream.Create;P:=TPicture.Create;B:=TBitmap.Create;
  try
    S.WriteBuffer(FImageJob.Data[0],Length(FImageJob.Data));S.Position:=0;P.LoadFromStream(S);B.Assign(P.Graphic);
    if B.Empty or (B.Width>8192) or (B.Height>8192) then raise Exception.Create('Invalid photo dimensions');
    FreeAndNil(FPhotos[N].Thumb);FPhotos[N].Thumb:=TBitmap.Create;
    W:=144;H:=Max(1,Round(W*B.Height/Max(1,B.Width)));if H>110 then begin H:=110;W:=Max(1,Round(H*B.Width/B.Height)) end;
    FPhotos[N].Thumb.SetSize(W,H);FPhotos[N].Thumb.Canvas.StretchDraw(Rect(0,0,W,H),B);
    Index:=FThumbOrder.IndexOf(Pointer(PtrInt(N)));
    if Index>=0 then FThumbOrder.Delete(Index);
    FThumbOrder.Add(Pointer(PtrInt(N)));
    { A full tile may contain thousands of photographs. Only decoded small
      previews are bounded here; every source remains browsable in the strip. }
    while FThumbOrder.Count>64 do begin
      Oldest:=PtrInt(FThumbOrder[0]);FThumbOrder.Delete(0);
      if Oldest=FSelected then FThumbOrder.Add(Pointer(PtrInt(Oldest)))
      else begin FreeAndNil(FPhotos[Oldest].Thumb);FPhotos[Oldest].Attempted:=False end;
    end;
    if N=FSelected then begin FBitmap.Assign(B);FMainIndex:=N;Arrange;UpdateStatus end;
    FStrip.Invalidate;
  finally B.Free;P.Free;S.Free end;
end;
procedure TStudioPhotoCompare.Tick(Sender:TObject);
var S:TJSONObject;HadRetired:Boolean;ErrorText:string;
begin
  HadRetired:=FRetiredJobs.Count>0;ReleaseFinishedJobs;
  if not Visible then begin FTimer.Enabled:=FRetiredJobs.Count>0;Exit end;
  if HadRetired and (FRetiredJobs.Count=0) then UpdateStatus;
  if (FJob<>nil) and FJob.Finished then begin
    { Do not replace the source array while a cache-image worker still owns
      its old index. Waiting here is a later timer tick, never a UI WaitFor. }
    if (FImageJob<>nil) and not FImageJob.Finished then Exit;
    if FImageJob<>nil then FreeAndNil(FImageJob);
    if FAcquiring then begin
      try AcquisitionFinished except on E:Exception do FAcquisitionNotice:=E.Message end;
      FreeAndNil(FJob);FAcquiring:=False;FCancel.Visible:=False;
      if FClosePending then begin CloseComparison;Exit end;
      StartGalleryRead;Arrange;
    end else if FWriting then begin
      ErrorText:='';
      try
        S:=FJob.ResultPage(0,100);
        try
          if not S.Get('saved',False) then raise Exception.Create(UiText('Photo review was not saved'));
          FAcquisitionNotice:=UiText('Photo review saved');
          if S.Get('compile_error','')<>'' then
            FAcquisitionNotice:=FAcquisitionNotice+' — '+S.Get('compile_error','');
          if S.Get('recipe_deactivated',False) then
            FAcquisitionNotice:=FAcquisitionNotice+' — '+UiText('Previous photo recipe disabled');
        finally S.Free end;
      except on E:Exception do ErrorText:=E.Message end;
      FreeAndNil(FJob);FWriting:=False;
      if ErrorText<>'' then FAcquisitionNotice:=ErrorText;
      StartGalleryRead;UpdateStatus;
    end else begin
      ErrorText:='';try ReadFinished except on E:Exception do ErrorText:=E.Message end;
      FreeAndNil(FJob);FWriting:=False;UpdateStatus;
      if ErrorText<>'' then SetStatus(ErrorText);
    end;
  end;
  if (FImageJob<>nil) and FImageJob.Finished then begin
    try ImageFinished except on E:Exception do begin
      if FImageJob.Index=FSelected then FFailedIndex:=FSelected;
      FPhotos[FImageJob.Index].Error:=E.Message;UpdateStatus;
    end end;
    FreeAndNil(FImageJob);
  end;
  if FReapply then begin
    FReapply:=False;
    try ApplySelected except on E:Exception do begin FApplied:=False;SetStatus(E.Message) end end;
  end;
  ScheduleImage;
  if FAcquiring and (FJob<>nil) then begin
    S:=FJob.Snapshot;
    try
      if FCancelRequested or S.Get('cancelled',False) or FClosePending then SetStatus(UiText('Cancelling photo download…'))
      else if S.Get('total',0)>0 then SetStatus(Format(UiText('Downloading photos: %d / %d'),
        [S.Get('completed',0),S.Get('total',0)]))
      else SetStatus(UiText('Finding nearby Mapillary photos…'));
    finally S.Free end;
  end;
end;
procedure TStudioPhotoCompare.ResetClick(Sender:TObject);
begin ResetView end;
procedure TStudioPhotoCompare.ResetView;
begin ApplySelected;UpdateStatus end;
procedure TStudioPhotoCompare.SaveClick(Sender:TObject);
begin try SaveCurrentView except on E:Exception do SetStatus(E.Message) end end;
procedure TStudioPhotoCompare.SaveCurrentView;
var V,C,Sample:TJSONObject;
begin
  if (FSelected<0) or (FMainIndex<>FSelected) or (FJob<>nil) then raise Exception.Create('Wait for the photo to load');
  Sample:=FRenderer.Sample(FViewport,FSession);V:=nil;
  try
    if FPhotos[FSelected].View<>nil then V:=CopyComparisonViewForTile(FPhotos[FSelected].View,FDocument)
    else V:=TJSONObject.Create(['id','view:studio:'+FPhotos[FSelected].Source.Get('id',''),
      'source_id',FPhotos[FSelected].Source.Get('id',''),'label',SourceLabel(FSelected),
      'image',TJSONObject.Create(['width_px',FBitmap.Width,'height_px',FBitmap.Height,
        'projection','perspective','crop',TJSONArray.Create([0,0,1,1])]),
      'anchors',TJSONArray.Create,'regions',TJSONArray.Create,'known_parameters',TJSONArray.Create]);
    V.Strings['status']:='draft';V.Floats['confidence']:=0.4;
    V.Strings['note']:='Camera placed manually in Studio; not a calibrated photogrammetric measurement.';
    V.Delete('camera');C:=TJSONObject(Sample.Find('camera').Clone);C.Floats['aspect_ratio']:=CroppedAspect;V.Add('camera',C);
    ValidatePhotoView(V);StartPhotoReview('','',V);
    SetStatus(UiText('Saving photo view…'));FSave.Enabled:=False;
  finally V.Free;Sample.Free end;
end;
procedure TStudioPhotoCompare.SourceClick(Sender:TObject);
begin if FSelected>=0 then OpenURL(FPhotos[FSelected].Source.Get('source_url','')) end;
function TStudioPhotoCompare.Snapshot:TJSONObject;
var A:TJSONArray;I:Integer;
begin
  A:=TJSONArray.Create;Result:=TJSONObject.Create(['open',Visible,'selected',FSelected,'photo_count',Length(FPhotos),
    'image_loaded',(FSelected>=0) and (FMainIndex=FSelected),'loading',FJob<>nil,'status',FStatus.Caption,'photos',A,
    'viewport_bounds',TJSONArray.Create([FHost.Left,FHost.Top,FHost.Width,FHost.Height]),
    'gallery_bounds',TJSONArray.Create([Left+FGallery.Left,Top+FGallery.Top,FGallery.Width,FGallery.Height]),
    'gallery_scroll',FGalleryScroll.Position,'gallery_canvas_width',FStrip.Width,
    'gallery_content_width',Length(FPhotos)*ThumbWidth]);
  Result.Add('acquiring',FAcquiring);Result.Add('close_pending',FClosePending);
  Result.Add('summary_text',FSummary.Caption);
  Result.Add('summary_bounds',TJSONArray.Create([Left+FSummary.Left,Top+FSummary.Top,FSummary.Width,FSummary.Height]));
  Result.Add('retired_workers',FRetiredJobs.Count);
  Result.Add('decoded_thumbnail_count',FThumbOrder.Count);
  Result.Add('acquisition_notice',FAcquisitionNotice);
  Result.Add('show_rejected',FShowRejected.Checked);
  if FEvidenceReport<>nil then Result.Add('evidence_report',FEvidenceReport.Clone);
  Result.Add('download_all_button_bounds',TJSONArray.Create([Left+FDownloadAll.Left,Top+FDownloadAll.Top,FDownloadAll.Width,FDownloadAll.Height]));
  Result.Add('review_button_bounds',TJSONArray.Create([Left+FReject.Left,Top+FReject.Top,FReject.Width,FReject.Height]));
  Result.Add('download_button_bounds',TJSONArray.Create([Left+FDownload.Left,Top+FDownload.Top,FDownload.Width,FDownload.Height]));
  Result.Add('sequence_button_bounds',TJSONArray.Create([Left+FSequence.Left,Top+FSequence.Top,FSequence.Width,FSequence.Height]));
  Result.Add('cancel_button_bounds',TJSONArray.Create([Left+FCancel.Left,Top+FCancel.Top,FCancel.Width,FCancel.Height]));
  if FAcquiring and (FJob<>nil) then Result.Add('acquisition_progress',FJob.Snapshot);
  if FProviderReports<>nil then Result.Add('providers',FProviderReports.Clone);
  for I:=0 to High(FPhotos) do A.Add(TJSONObject.Create(['id',FPhotos[I].Source.Get('id',''),
    'kind',FPhotos[I].Source.Get('kind',''),'provider',FPhotos[I].Source.Get('provider',''),
    'sequence_id',FPhotos[I].Source.Get('sequence_id',''),'sequence_index',FPhotos[I].Source.Get('sequence_index',-1),
    'rejected',not IsComparisonSource(FPhotos[I].Source),'review_status',FPhotos[I].Source.Get('review_status','unreviewed'),
    'review_note',FPhotos[I].Source.Get('review_note',''),
    'has_view',FPhotos[I].View<>nil,'approximate_view_available',FPhotos[I].Source.Find('latitude')<>nil,
    'thumbnail_loaded',FPhotos[I].Thumb<>nil]));
end;
end.
