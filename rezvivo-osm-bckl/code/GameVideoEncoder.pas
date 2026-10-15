unit GameVideoEncoder;
{$mode objfpc}{$H+}
interface
uses Classes, SyncObjs, ProcessUnicode, CastleImages;
type
  { One bounded frame slot, owned by the encoder after Submit. No frame files,
    no unbounded queue, no GL on the worker. Back pressure holds virtual time. }
  TVideoEncoder = class(TThread)
  private
    FProcess: ProcessUnicode.TProcess;
    FLock: TCriticalSection;
    FWake: TEvent;
    FFrame: TRGBImage;
    FWriting, FFinishing, FDone: Boolean;
    FSent, FEncoded: Int64;
    FError, FProgress, FLog: String;
    FProcessId: Cardinal;
    procedure ReadOutput;
    procedure WriteFrame(Image: TRGBImage);
  protected
    procedure Execute; override;
  public
    constructor Create(const Encoder, Output: String; Width, Height, Fps: Integer);
    destructor Destroy; override;
    function Ready: Boolean;
    function Submit(Image: TRGBImage): Boolean;
    procedure Finish;
    function Done: Boolean;
    function Error: String;
    function EncodedFrames: Int64;
    property ProcessId: Cardinal read FProcessId;
  end;
implementation
uses SysUtils, Math, Process;

constructor TVideoEncoder.Create(const Encoder, Output: String; Width, Height, Fps: Integer);
  procedure Arg(const S: String);
  begin FProcess.Parameters.Add(UTF8Decode(S)) end;
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FLock:=TCriticalSection.Create;
  FWake:=TEvent.Create(nil,False,False,'');
  FProcess:=ProcessUnicode.TProcess.Create(nil);
  FProcess.Executable:=UTF8Decode(Encoder);
  FProcess.Options:=[poUsePipes,poStderrToOutPut,poNoConsole];
  FProcess.ShowWindow:=swoHIDE;
  Arg('-hide_banner'); Arg('-nostdin'); Arg('-loglevel'); Arg('error');
  Arg('-nostats'); Arg('-progress'); Arg('pipe:1');
  Arg('-f'); Arg('rawvideo'); Arg('-pixel_format'); Arg('rgb24');
  Arg('-video_size'); Arg(Format('%dx%d',[Width,Height]));
  Arg('-framerate'); Arg(IntToStr(Fps)); Arg('-i'); Arg('pipe:0');
  Arg('-an'); Arg('-c:v'); Arg('libx264'); Arg('-preset'); Arg('veryfast');
  Arg('-crf'); Arg('18'); Arg('-pix_fmt'); Arg('yuv420p');
  { CGE images start at the lower left; pad odd window sizes without resizing. }
  Arg('-vf'); Arg('vflip,pad=ceil(iw/2)*2:ceil(ih/2)*2');
  Arg('-threads'); Arg('2'); Arg('-filter_threads'); Arg('1');
  Arg('-g'); Arg(IntToStr(Fps*2));
  { Retain completed fragments even on failure. EOF flushes the final B-frames. }
  Arg('-movflags'); Arg('+frag_keyframe+empty_moov+default_base_moof');
  Arg('-frag_duration'); Arg('1000000'); Arg('-n'); Arg(Output);
  try FProcess.Execute; FProcessId:=FProcess.ProcessID;
  except FDone:=True; raise end;
  Start;
end;

destructor TVideoEncoder.Destroy;
var Deadline: QWord;
begin
  if (FLock<>nil) and (FWake<>nil) then begin
    Finish;
    Deadline:=GetTickCount64+2000;
    while not Done and (GetTickCount64<Deadline) do Sleep(10);
    if not Done then begin
      Terminate;
      if (FProcess<>nil) and FProcess.Running then FProcess.Terminate(1);
      FWake.SetEvent;
    end;
    if FProcessId<>0 then WaitFor;
  end;
  inherited;
  FreeAndNil(FFrame);
  FreeAndNil(FProcess); FreeAndNil(FWake); FreeAndNil(FLock);
end;

function TVideoEncoder.Ready: Boolean;
begin
  FLock.Enter;
  try Result:=not FDone and not FFinishing and not FWriting and (FFrame=nil);
  finally FLock.Leave end;
end;
function TVideoEncoder.Submit(Image: TRGBImage): Boolean;
begin
  FLock.Enter;
  try
    Result:=not FDone and not FFinishing and not FWriting and (FFrame=nil);
    if Result then FFrame:=Image;
  finally FLock.Leave end;
  if Result then FWake.SetEvent;
end;
procedure TVideoEncoder.Finish;
begin
  FLock.Enter; try FFinishing:=True finally FLock.Leave end;
  FWake.SetEvent;
end;
function TVideoEncoder.Done: Boolean;
begin FLock.Enter; try Result:=FDone finally FLock.Leave end end;
function TVideoEncoder.Error: String;
begin FLock.Enter; try Result:=FError finally FLock.Leave end end;
function TVideoEncoder.EncodedFrames: Int64;
begin FLock.Enter; try Result:=FEncoded finally FLock.Leave end end;

procedure TVideoEncoder.ReadOutput;
var Buffer: array[0..4095] of Byte; Chunk,Line:String; N,P:Integer;
begin
  while FProcess.Output.NumBytesAvailable>0 do begin
    N:=FProcess.Output.Read(Buffer,SizeOf(Buffer)); if N<=0 then Break;
    SetString(Chunk,PChar(@Buffer[0]),N);
    FProgress:=FProgress+Chunk;
    repeat
      P:=Pos(#10,FProgress); if P=0 then Break;
      Line:=Trim(Copy(FProgress,1,P-1)); Delete(FProgress,1,P);
      if Copy(Line,1,6)='frame=' then begin
        FLock.Enter;
        try FEncoded:=StrToInt64Def(Trim(Copy(Line,7,MaxInt)),FEncoded);
        finally FLock.Leave end;
      end else if Pos('=',Line)=0 then FLog:=Copy(FLog+Line+#10,1,4096);
    until False;
    if Length(FProgress)>8192 then FProgress:='';
  end;
end;

procedure TVideoEncoder.WriteFrame(Image:TRGBImage);
var Data:PByte; Left:SizeInt; N:LongInt;
begin
  Data:=Image.RawPixels; Left:=SizeInt(Image.Width)*Image.Height*3;
  while Left>0 do begin
    if Terminated then raise Exception.Create('Video encoding interrupted');
    ReadOutput;
    N:=FProcess.Input.Write(Data^,Min(Left,SizeInt(65536)));
    if N<=0 then raise Exception.Create('Video encoder closed its input: '+FLog);
    Inc(Data,N); Dec(Left,N);
  end;
end;

procedure TVideoEncoder.Execute;
var Image:TRGBImage; Finishing:Boolean;
begin
  if Terminated then Exit;
  try
    while not Terminated do begin
      FLock.Enter;
      try
        Image:=FFrame; FFrame:=nil; FWriting:=Image<>nil;
        Finishing:=FFinishing;
      finally FLock.Leave end;
      if Image<>nil then begin
        try WriteFrame(Image); Inc(FSent) finally Image.Free end;
        FLock.Enter; try FWriting:=False finally FLock.Leave end;
      end else if Finishing then Break
      else FWake.WaitFor(50);
      ReadOutput;
      if not FProcess.Running then
        raise Exception.Create(Format('FFmpeg exit %d: %s',[FProcess.ExitStatus,FLog]));
    end;
    FProcess.CloseInput;
    while FProcess.Running and not Terminated do begin ReadOutput; Sleep(10) end;
    ReadOutput;
    if Terminated then raise Exception.Create('Video encoding interrupted');
    if FProcess.ExitStatus<>0 then
      raise Exception.Create(Format('FFmpeg exit %d: %s',[FProcess.ExitStatus,FLog]));
    if FEncoded<>FSent then raise Exception.Create('Video encoder did not finish every frame');
  except on E:Exception do begin
    if FProcess.Running then FProcess.Terminate(1);
    FLock.Enter; try FError:=E.Message finally FLock.Leave end;
  end end;
  FLock.Enter;
  try FreeAndNil(FFrame); FWriting:=False; FDone:=True;
  finally FLock.Leave end;
end;
end.
