unit GameVideoCapture;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, fpjson, CastleUIControls;
function CreateGameVideoControl(AOwner: TComponent): TCastleUserInterface;
procedure StartGameVideo;
procedure StopGameVideo;
function GameVideoRecording: Boolean;
function GameVideoBusy: Boolean;
function GameVideoStatus: TJSONObject;
function GameVideoWindTime: Single;
function GameVideoSurfaceTime: Single;
implementation
uses SysUtils, CastleKeysMouse, CastleNotifications, CastleImages, CastleGLImages,
  CastleGLUtils, CastleTimeUtils, AppRuntimePaths, UiTranslations, DebugLog,
  GameVideoClock, GameVideoEncoder, Osm3dWind, Osm3dCompositeShader;
type
  TVideoState = (vsIdle,vsCapturing,vsEncoding,vsDone,vsError);
  TGameVideoControl = class(TCastleUserInterface)
  private
    FState:TVideoState;
    FEncoder:TVideoEncoder;
    FNotice:TCastleNotifications;
    FOutput,FPartial,FError:String;
    FWidth,FHeight:Integer;
    FEncodedFrames:Int64;
    FLastCaptureFrame:TFrameId;
    FEscapeHeld:Boolean;
    FWindStart,FSurfaceStart:Single;
    FOriginalView:TCastleView;
    procedure StartCapture;
    procedure StopCapture;
    procedure CaptureFrame;
    procedure PollEncoder;
    procedure Fail(const MessageText:String);
    function Status:TJSONObject;
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    procedure Render;override;
    function PreviewPress(const Event:TInputPressRelease):Boolean;override;
    function Release(const Event:TInputPressRelease):Boolean;override;
  end;
const StateNames:array[TVideoState]of String=('idle','recording','encoding','done','error');
var VideoControl:TGameVideoControl;

function FindEncoder:String;
var Candidate,Part,Paths:String;P:SizeInt;
const ExeName={$ifdef MSWINDOWS}'ffmpeg.exe'{$else}'ffmpeg'{$endif};
begin
  Result:=AppDirectory+'tools'+PathDelim+'video'+PathDelim+ExeName;
  if FileExists(Result) then Exit;
  Result:=AppDirectory+ExeName;
  if FileExists(Result) then Exit;
  Paths:=GetEnvironmentVariable('PATH');
  while Paths<>'' do begin
    P:=Pos(PathSeparator,Paths);if P=0 then P:=Length(Paths)+1;
    Part:=Copy(Paths,1,P-1);Delete(Paths,1,P);if Part='' then Continue;
    Candidate:=IncludeTrailingPathDelimiter(Part)+ExeName;
    if FileExists(Candidate) then Exit(Candidate);
  end;
  Result:='';
end;

constructor TGameVideoControl.Create(AOwner:TComponent);
begin
  inherited;
  Name:='VideoCapture';FullSize:=True;KeepInFront:=True;
  { Observe Esc, return False for everything else. Never block underlying UI. }
  CapturesEvents:=True;
  FNotice:=TCastleNotifications.Create(Self);
  FNotice.Name:='VideoNotification';FNotice.CapturesEvents:=False;
  FNotice.Anchor(hpMiddle);FNotice.Anchor(vpTop,-160);
  FNotice.TextAlignment:=hpMiddle;FNotice.FontSize:=18;
  FNotice.Timeout:=10;FNotice.MaxMessages:=1;InsertFront(FNotice);
end;

destructor TGameVideoControl.Destroy;
begin
  StopCapture;
  { Bounded drain on shutdown. Completed fragments survive an interruption. }
  FreeAndNil(FEncoder);
  OfflineVideoClock.Stop;WindSetOfflineTime(-1);
  if VideoControl=Self then VideoControl:=nil;
  inherited;
end;

function TGameVideoControl.Status:TJSONObject;
begin
  Result:=TJSONObject.Create;
  Result.Add('state',StateNames[FState]);Result.Add('fps',VideoFramesPerSecond);
  Result.Add('frames',OfflineVideoClock.Frames);
  Result.Add('duration',OfflineVideoClock.Frames/VideoFramesPerSecond);
  Result.Add('width',FWidth);Result.Add('height',FHeight);
  Result.Add('file',FOutput);Result.Add('partial_file',FPartial);Result.Add('error',FError);
  Result.Add('frame_files',0);Result.Add('max_buffered_frames',1);
  if FEncoder<>nil then begin
    Result.Add('encoded_frames',FEncoder.EncodedFrames);
    Result.Add('encoder_pid',Int64(FEncoder.ProcessId));
  end else Result.Add('encoded_frames',FEncodedFrames);
end;

procedure TGameVideoControl.Fail(const MessageText:String);
begin
  OfflineVideoClock.Stop;WindSetOfflineTime(-1);
  if Container<>nil then Container.Fps.ZeroNextSecondsPassed;
  FState:=vsError;FError:=MessageText;FNotice.Exists:=True;FNotice.Clear;
  FNotice.Show(Format(UiText('Video recording failed: %s'),[MessageText]));
  Logger.Warning('[Video] '+MessageText+'; partial='+FPartial);
end;

procedure TGameVideoControl.StartCapture;
var Base,Directory,Encoder:String;Suffix:Integer;
begin
  if FState in[vsCapturing,vsEncoding] then Exit;
  FOutput:='';FPartial:='';FError:='';FEncodedFrames:=0;
  try
    if (Container=nil) or not Container.GLInitialized then
      raise Exception.Create(UiText('Start a ride before recording video.'));
    Encoder:=FindEncoder;
    if Encoder='' then raise Exception.Create(UiText('Video encoder not found in tools/video.'));
    Directory:=IncludeTrailingPathDelimiter(AppDirectory+'videos');
    if not ForceDirectories(Directory) then raise Exception.Create(Directory);
    Base:=Directory+'REZVIVO_'+FormatDateTime('yyyy-mm-dd_hh-nn-ss-zzz',Now);
    Suffix:=0;FOutput:=Base+'.mp4';FPartial:=Base+'.partial.mp4';
    while FileExists(FOutput) or FileExists(FPartial) do begin
      Inc(Suffix);FOutput:=Base+'_'+IntToStr(Suffix)+'.mp4';
      FPartial:=ChangeFileExt(FOutput,'.partial.mp4');
    end;
    FWidth:=Container.PixelsWidth;FHeight:=Container.PixelsHeight;
    FEncoder:=TVideoEncoder.Create(Encoder,FPartial,FWidth,FHeight,VideoFramesPerSecond);
    FOriginalView:=Container.PendingFrontView;
    FWindStart:=WindNow;FSurfaceStart:=CompositeShaderMaxClock;
    FLastCaptureFrame:=0;
    FState:=vsCapturing;OfflineVideoClock.Start;
    FNotice.Clear;FNotice.Exists:=False;Container.Invalidate;
    Logger.Info('[Video] Streaming 30 fps to '+FOutput+'; Esc finishes');
  except on E:Exception do Fail(E.Message) end;
end;

procedure TGameVideoControl.CaptureFrame;
var Img:TRGBImage;
begin
  if not OfflineVideoClock.Pending then Exit;
  { MCP SaveScreen can redraw during Update. Only an ordinary window render
    after InternalRenderBegin owns a complete frame; never render recursively. }
  if (TFramesPerSecond.RenderFrameId<>TFramesPerSecond.FrameId) or
     (FLastCaptureFrame=TFramesPerSecond.FrameId) then Exit;
  if (Container.PixelsWidth<>FWidth) or(Container.PixelsHeight<>FHeight) then begin
    StopCapture;Exit;
  end;
  if (FEncoder=nil) or not FEncoder.Ready then Exit;
  try
    TDrawableImage.BatchingFlush;
    Img:=SaveScreen_NoFlush(Container.PixelsRect,cbBack);
    if FEncoder.Submit(Img) then begin
      { The encoder frees Img as soon as the pipe consumes it. }
      FLastCaptureFrame:=TFramesPerSecond.FrameId;
      OfflineVideoClock.FrameSaved;
    end else Img.Free;
  except on E:Exception do begin FreeAndNil(FEncoder);Fail(E.Message) end end;
end;

procedure TGameVideoControl.StopCapture;
begin
  if FState<>vsCapturing then Exit;
  OfflineVideoClock.Stop;WindSetOfflineTime(-1);
  if Container<>nil then Container.Fps.ZeroNextSecondsPassed;
  FState:=vsEncoding;
  FNotice.Exists:=True;FNotice.Show(UiText('Finishing video...'));
  if FEncoder<>nil then FEncoder.Finish;
end;

procedure TGameVideoControl.PollEncoder;
var ErrorText:String;Stream:TFileStream;Size:Int64;
begin
  if (FEncoder=nil) or not FEncoder.Done then Exit;
  try
    ErrorText:=FEncoder.Error;FEncodedFrames:=FEncoder.EncodedFrames;
    FreeAndNil(FEncoder);
    if (OfflineVideoClock.Frames=0) and(FState=vsEncoding)then begin
      DeleteFile(FPartial);FState:=vsIdle;FNotice.Clear;Exit;
    end;
    if ErrorText<>'' then raise Exception.Create(ErrorText);
    if FState<>vsEncoding then raise Exception.Create('Video encoder stopped unexpectedly');
    Stream:=TFileStream.Create(FPartial,fmOpenRead or fmShareDenyNone);
    try Size:=Stream.Size finally Stream.Free end;
    if (FEncodedFrames<>OfflineVideoClock.Frames) or(Size<128) then
      raise Exception.Create(UiText('Incomplete video; the partial file was preserved.'));
    if not RenameFile(FPartial,FOutput) then raise Exception.Create(FOutput);
    FState:=vsDone;FNotice.Clear;
    FNotice.Show(Format(UiText('Video saved: %s'),[FOutput]));
    Logger.Info(Format('[Video] Saved %d frames to %s',[FEncodedFrames,FOutput]));
  except on E:Exception do Fail(E.Message) end;
end;

procedure TGameVideoControl.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var Dt:Single;
begin
  inherited;
  PollEncoder;
  if FState<>vsCapturing then Exit;
  if Container.PendingFrontView<>FOriginalView then begin StopCapture;Exit end;
  Dt:=0;
  if (FEncoder<>nil) and FEncoder.Ready then Dt:=OfflineVideoClock.BeginFrame;
  Container.Fps.OverrideSecondsPassed(Dt);
  WindSetOfflineTime(OfflineVideoClock.Seconds);
  Container.Invalidate;
end;

procedure TGameVideoControl.Render;
begin inherited;if FState=vsCapturing then CaptureFrame end;
function TGameVideoControl.PreviewPress(const Event:TInputPressRelease):Boolean;
begin
  if ((FState in[vsCapturing,vsEncoding]) or FEscapeHeld) and Event.IsKey(keyEscape) then begin
    FEscapeHeld:=True;
    if not Event.KeyRepeated then StopCapture;
    Exit(True);
  end;
  Result:=inherited;
end;

function TGameVideoControl.Release(const Event:TInputPressRelease):Boolean;
begin
  if FEscapeHeld and Event.IsKey(keyEscape) then begin
    FEscapeHeld:=False;Exit(True);
  end;
  Result:=inherited;
end;

function CreateGameVideoControl(AOwner:TComponent):TCastleUserInterface;
begin VideoControl:=TGameVideoControl.Create(AOwner);Result:=VideoControl end;
procedure StartGameVideo;
begin if VideoControl<>nil then VideoControl.StartCapture end;
procedure StopGameVideo;
begin if VideoControl<>nil then VideoControl.StopCapture end;
function GameVideoRecording:Boolean;
begin Result:=OfflineVideoClock.Active end;
function GameVideoBusy:Boolean;
begin Result:=(VideoControl<>nil)and(VideoControl.FState in[vsCapturing,vsEncoding]) end;
function GameVideoStatus:TJSONObject;
begin
  if VideoControl<>nil then Result:=VideoControl.Status
  else Result:=TJSONObject.Create(['state','unavailable']);
end;
function GameVideoWindTime:Single;
begin Result:=VideoControl.FWindStart+OfflineVideoClock.Seconds end;
function GameVideoSurfaceTime:Single;
begin Result:=VideoControl.FSurfaceStart+OfflineVideoClock.Seconds end;
end.
