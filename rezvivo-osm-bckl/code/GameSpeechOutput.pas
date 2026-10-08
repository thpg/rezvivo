unit GameSpeechOutput;
{$mode objfpc}{$H+}{$codepage UTF8}
{ SAPI objects never leave their COM worker. Main-thread methods only exchange
  bounded text/status under a lock. No text or audio is written to disk. }
interface
uses Classes,SysUtils,SyncObjs;
const
  SPEECH_QUEUE_LIMIT=4;
  SPEECH_TEXT_LIMIT=1200; { Unicode code units; around two minutes maximum }
type
  TSpeechOutputStatus=record
    Revision,CancelCompleted:QWord;
    Ready,Available,Speaking,LanguageMatch:Boolean;
    QueueCount:Integer;
    VoiceName,VoiceLanguage,RequestedLanguage,Error:string;
  end;
  TSpeechOutput=class;
  TSpeechOutputThread=class(TThread)
  private FOwner:TSpeechOutput;
  protected procedure Execute;override;
  public constructor Create(AOwner:TSpeechOutput);
  end;
  TSpeechOutput=class
  private
    FLock:TCriticalSection;
    FWake:TEvent;
    FThread:TSpeechOutputThread;
    FStatus:TSpeechOutputStatus;
    FLanguage:string;
    FCancel:QWord;
    FVolume:Integer;
    FQueue:array of UnicodeString;
    FSilentTest:Boolean;
    FTestPCM:TBytes;
    procedure EnsureWorker;
  public
    constructor Create(const SilentMemoryTest:Boolean=False);
    destructor Destroy;override;
    procedure Configure(const Language:string);
    procedure SetVolume(Value:Integer);
    function Enqueue(const Text:string):Boolean;
    function Cancel:QWord;
    function Status:TSpeechOutputStatus;
    function CopyTestPCM:TBytes; { only populated by explicit silent test mode }
  end;
function SpeechPlainText(const Text:string):UnicodeString;
implementation
{$ifdef MSWINDOWS}
uses Windows,ActiveX,ComObj,Variants;
{$endif}

function SpeechPlainText(const Text:string):UnicodeString;
var I,N:Integer;S:UnicodeString;
begin
  S:=UTF8Decode(Text);N:=Length(S);if N>SPEECH_TEXT_LIMIT then N:=SPEECH_TEXT_LIMIT;
  { Do not split a UTF-16 surrogate pair at the length limit. }
  if (N>0) and (Ord(S[N])>=$D800) and (Ord(S[N])<=$DBFF) then Dec(N);
  Result:=Copy(S,1,N);
  for I:=1 to Length(Result) do if Ord(Result[I])<32 then Result[I]:=' ';
  Result:=Trim(Result);
end;
constructor TSpeechOutput.Create(const SilentMemoryTest:Boolean);
begin
  inherited Create;FLock:=SyncObjs.TCriticalSection.Create;FWake:=SyncObjs.TEvent.Create(nil,False,False,'');
  FSilentTest:=SilentMemoryTest;FVolume:=100;
end;
destructor TSpeechOutput.Destroy;
begin
  if FThread<>nil then begin FThread.Terminate;FWake.SetEvent;FThread.WaitFor;FThread.Free end;
  FWake.Free;FLock.Free;inherited;
end;
procedure TSpeechOutput.EnsureWorker;
begin
  if (FThread<>nil) and FThread.Finished then FreeAndNil(FThread);
  if FThread=nil then FThread:=TSpeechOutputThread.Create(Self);
end;
procedure TSpeechOutput.Configure(const Language:string);
begin
  FLock.Acquire;
  try
    if (FThread=nil) or FThread.Finished then FStatus.Ready:=False;
    if FLanguage<>LowerCase(Language) then begin
      FLanguage:=LowerCase(Language);FQueue:=nil;Inc(FCancel);
      FStatus.Ready:=False;FStatus.RequestedLanguage:=FLanguage;Inc(FStatus.Revision);
    end;
  finally FLock.Release end;
  EnsureWorker;FWake.SetEvent;
end;
procedure TSpeechOutput.SetVolume(Value:Integer);
begin
  if Value<0 then Value:=0 else if Value>100 then Value:=100;
  FLock.Acquire;
  try
    if FVolume=Value then Exit;FVolume:=Value;
    if Value=0 then begin FQueue:=nil;FStatus.QueueCount:=0;Inc(FCancel) end;
    Inc(FStatus.Revision);
  finally FLock.Release end;
  FWake.SetEvent;
end;
function TSpeechOutput.Enqueue(const Text:string):Boolean;
var S:UnicodeString;N:Integer;
begin
  Result:=False;S:=SpeechPlainText(Text);if S='' then Exit;
  FLock.Acquire;
  try
    N:=Length(FQueue);if N>=SPEECH_QUEUE_LIMIT then Exit;
    if FStatus.Ready and (not FStatus.Available or not FStatus.LanguageMatch) then Exit;
    SetLength(FQueue,N+1);FQueue[N]:=S;FStatus.QueueCount:=N+1;Inc(FStatus.Revision);Result:=True;
  finally FLock.Release end;
  EnsureWorker;FWake.SetEvent;
end;
function TSpeechOutput.Cancel:QWord;
begin
  FLock.Acquire;
  try
    FQueue:=nil;Inc(FCancel);Result:=FCancel;FStatus.QueueCount:=0;Inc(FStatus.Revision);
    if (FThread=nil) or (FStatus.Ready and not FStatus.Available) then FStatus.CancelCompleted:=FCancel;
  finally FLock.Release end;
  FWake.SetEvent;
end;
function TSpeechOutput.Status:TSpeechOutputStatus;
begin FLock.Acquire;try Result:=FStatus finally FLock.Release end end;
function TSpeechOutput.CopyTestPCM:TBytes;
begin FLock.Acquire;try Result:=Copy(FTestPCM) finally FLock.Release end end;
constructor TSpeechOutputThread.Create(AOwner:TSpeechOutput);
begin inherited Create(True);FOwner:=AOwner;FreeOnTerminate:=False;Start end;

{$ifdef MSWINDOWS}
function TokenLanguage(const Token:OleVariant):string;
var S:string;P,L:Integer;Buffer:array[0..31]of WideChar;
begin
  Result:='';S:=VarToStr(Token.GetAttribute('Language'));P:=Pos(';',S);if P>0 then S:=Copy(S,1,P-1);
  L:=StrToIntDef('$'+S,0);
  if (L<>0) and (GetLocaleInfoW(L,$59,@Buffer[0],Length(Buffer))>0) then Result:=LowerCase(UTF8Encode(UnicodeString(PWideChar(@Buffer[0]))));
end;
procedure SelectVoice(const Voice:OleVariant;const Language:string;out Name,Actual:string;out Matched:Boolean);
var Tokens,T:OleVariant;I:Integer;Wanted:string;
begin
  Wanted:=Copy(LowerCase(Language),1,2);Tokens:=Voice.GetVoices('','');Matched:=False;
  for I:=0 to Integer(Tokens.Count)-1 do begin
    T:=Tokens.Item(I);
    if TokenLanguage(T)=Wanted then begin Voice.Voice:=T;Matched:=True;Break end;
  end;
  T:=Voice.Voice;Name:=UTF8Encode(UnicodeString(T.GetDescription(0)));Actual:=TokenLanguage(T);
end;
{$endif}

procedure TSpeechOutputThread.Execute;
{$ifdef MSWINDOWS}
var Voice,Memory,Data,Format:OleVariant;Lang,CurrentLang,Name,Actual:string;Text:UnicodeString;
  CancelNow,CancelApplied:QWord;Speaking,Matched,Ready,NeedConfig:Boolean;I,N,Volume,LastVolume:Integer;
  Init:HRESULT;PCM:TBytes;Ptr:Pointer;
{$endif}
begin
  {$ifdef MSWINDOWS}
  Init:=CoInitializeEx(nil,COINIT_MULTITHREADED);Voice:=Unassigned;Memory:=Unassigned;
  Speaking:=False;Ready:=False;CurrentLang:='';CancelApplied:=0;LastVolume:=-1;Matched:=False;
  try
    try
      if Init<0 then raise Exception.Create('COM unavailable');
      Voice:=CreateOleObject('SAPI.SpVoice');
      while not Terminated do begin
        Text:='';FOwner.FLock.Acquire;
        try
          Lang:=FOwner.FLanguage;CancelNow:=FOwner.FCancel;Volume:=FOwner.FVolume;
          NeedConfig:=not Ready or (Lang<>CurrentLang);
        finally FOwner.FLock.Release end;
        if Volume<>LastVolume then begin Voice.Volume:=Volume;LastVolume:=Volume end;
        if CancelNow<>CancelApplied then begin
          { Empty synchronous purge runs only on this worker. Its return is
            the fence used before the coordinator opens the microphone. }
          Voice.Speak(WideString(''),2 or 16);Speaking:=False;CancelApplied:=CancelNow;
          FOwner.FLock.Acquire;
          try
            FOwner.FStatus.Speaking:=False;FOwner.FStatus.CancelCompleted:=CancelApplied;
            Inc(FOwner.FStatus.Revision);
          finally FOwner.FLock.Release end;
          Memory:=Unassigned;
        end;
        if NeedConfig then begin
          SelectVoice(Voice,Lang,Name,Actual,Matched);CurrentLang:=Lang;Ready:=True;
          FOwner.FLock.Acquire;
          try
            FOwner.FStatus.Ready:=True;FOwner.FStatus.Available:=True;
            FOwner.FStatus.VoiceName:=Name;FOwner.FStatus.VoiceLanguage:=Actual;
            FOwner.FStatus.LanguageMatch:=Matched;
            if Matched then FOwner.FStatus.Error:='' else begin
              FOwner.FStatus.Error:='speech_voice_language_unavailable';FOwner.FQueue:=nil;FOwner.FStatus.QueueCount:=0;
            end;
            Inc(FOwner.FStatus.Revision);
          finally FOwner.FLock.Release end;
        end;
        if Speaking and Boolean(Voice.WaitUntilDone(0)) then begin
          Speaking:=False;
          if FOwner.FSilentTest then begin
            Data:=Memory.GetData;N:=VarArrayHighBound(Data,1)-VarArrayLowBound(Data,1)+1;
            if N>8*1024*1024 then N:=8*1024*1024;
            SetLength(PCM,N);Ptr:=VarArrayLock(Data);try if N>0 then Move(Ptr^,PCM[0],N) finally VarArrayUnlock(Data) end;
            FOwner.FLock.Acquire;try FOwner.FTestPCM:=PCM finally FOwner.FLock.Release end;
            Data:=Unassigned;Memory:=Unassigned;
          end;
          FOwner.FLock.Acquire;
          try FOwner.FStatus.Speaking:=False;Inc(FOwner.FStatus.Revision) finally FOwner.FLock.Release end;
        end;
        if not Speaking and Matched then begin
          FOwner.FLock.Acquire;
          try
            N:=Length(FOwner.FQueue);
            if (N>0) and (FOwner.FCancel=CancelApplied) then begin
              Text:=FOwner.FQueue[0];for I:=0 to N-2 do FOwner.FQueue[I]:=FOwner.FQueue[I+1];
              SetLength(FOwner.FQueue,N-1);FOwner.FStatus.QueueCount:=N-1;
              FOwner.FStatus.Speaking:=True;Inc(FOwner.FStatus.Revision);
            end;
          finally FOwner.FLock.Release end;
          if Text<>'' then begin
            if FOwner.FSilentTest then begin
              Memory:=CreateOleObject('SAPI.SpMemoryStream');Format:=Memory.Format;Format.&Type:=18;Memory.Format:=Format;
              Voice.AllowAudioOutputFormatChangesOnNextSet:=False;Voice.AudioOutputStream:=Memory;
            end;
            Voice.Speak(WideString(Text),1 or 16);Speaking:=True;
          end;
        end;
        if Speaking then FOwner.FWake.WaitFor(20) else FOwner.FWake.WaitFor(INFINITE);
      end;
    except
      FOwner.FLock.Acquire;
      try
        FOwner.FStatus.Ready:=True;FOwner.FStatus.Available:=False;FOwner.FStatus.Speaking:=False;
        FOwner.FStatus.Error:='speech_output_unavailable';FOwner.FQueue:=nil;FOwner.FStatus.QueueCount:=0;
        FOwner.FStatus.CancelCompleted:=FOwner.FCancel;Inc(FOwner.FStatus.Revision);
      finally FOwner.FLock.Release end;
    end;
  finally
    if not VarIsEmpty(Voice) then try Voice.Speak(WideString(''),1 or 2 or 16) except end;
    Memory:=Unassigned;Voice:=Unassigned;if Init>=0 then CoUninitialize;
  end;
  {$else}
  FOwner.FLock.Acquire;
  try
    FOwner.FStatus.Ready:=True;FOwner.FStatus.Error:='speech_output_unavailable';
    FOwner.FStatus.CancelCompleted:=FOwner.FCancel;Inc(FOwner.FStatus.Revision);
  finally FOwner.FLock.Release end;
  {$endif}
end;
end.
