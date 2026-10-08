unit GameAssistantVoice;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses SysUtils,fpjson,GameSpeechOutput,GameSpeechInput;
type
  TGameAssistantVoice=class
  private
    FOutput:TSpeechOutput;
    FInputCreated,FWaitingInput,FConnected,FEnabled:Boolean;
    FRevision,FNextUpdate,FNextContext,FCancelBeforeInput:QWord;
    FOutputRevision,FInputRevision:QWord;
    FLastReplyId:Int64;
    FContextDir,FLanguage,FTranscript,FOutputError,FInputError:string;
    FInput:TSpeechInputSnapshot;
    FMaster:Integer;
    procedure SyncContext;
    procedure EnsureOutput;
    function InputActive:Boolean;
  public
    constructor Create;
    destructor Destroy;override;
    procedure SetSpeakEnabled(Value:Boolean);
    procedure StartInput;
    procedure StopInput;
    procedure CancelInput;
    procedure StopSpeech;
    procedure Update;
    function TakeTranscript(out Text:string):Boolean;
    function Snapshot:TJSONObject;
    procedure SessionStarted;
    procedure SessionEnded;
    procedure ReplyAdded(const Id:Int64;const Text:string);
    property SpeakEnabled:Boolean read FEnabled;
    property Revision:QWord read FRevision;
  end;
function AssistantVoice:TGameAssistantVoice;
procedure UpdateAssistantVoice;
procedure ShutdownAssistantVoice;
procedure CancelAssistantVoiceInput;
procedure EndAssistantVoiceSession;
{ A retry and an old history entry must never become audible a second time,
  including after enabling speech or after microphone recording finishes. }
function AcceptSpeechReply(Id:Int64;Enabled,InputBusy:Boolean;var LastId:Int64):Boolean;
implementation
uses GameAssistant,GameUserData,GameLocalization,AppSettings;
var Instance:TGameAssistantVoice;

function AcceptSpeechReply(Id:Int64;Enabled,InputBusy:Boolean;var LastId:Int64):Boolean;
begin
  Result:=False;if (Id<=0) or (Id<=LastId) then Exit;
  LastId:=Id;Result:=Enabled and not InputBusy;
end;
function AssistantVoice:TGameAssistantVoice;
begin if Instance=nil then Instance:=TGameAssistantVoice.Create;Result:=Instance end;
procedure UpdateAssistantVoice;
begin if Instance<>nil then Instance.Update end;
procedure ShutdownAssistantVoice;
begin FreeAndNil(Instance);ShutdownSpeechInput end;
procedure CancelAssistantVoiceInput;
begin if Instance<>nil then Instance.CancelInput end;
procedure EndAssistantVoiceSession;
begin if Instance<>nil then Instance.SessionEnded end;
constructor TGameAssistantVoice.Create;
begin
  inherited Create;FInput.State:=sisIdle;FMaster:=-1;SyncContext;
end;
destructor TGameAssistantVoice.Destroy;
begin SessionEnded;FOutput.Free;inherited end;
procedure TGameAssistantVoice.SyncContext;
var Dir,Lang:string;Master:Integer;
begin
  Dir:=UserDataDir;
  if Dir<>FContextDir then begin
    if FContextDir<>'' then SessionEnded;
    FContextDir:=Dir;FEnabled:=UserPreferences.Get('assistant_speak_replies',False);Inc(FRevision);
  end;
  Lang:=CurrentAppliedLanguage;if Lang='' then Lang:=EffectiveLanguage;
  if Lang<>FLanguage then begin
    FLanguage:=Lang;if FOutput<>nil then FOutput.Configure(Lang);
    if InputActive then CancelInput;Inc(FRevision);
  end;
  Master:=Settings.AudioMaster;
  if Master<>FMaster then begin FMaster:=Master;if FOutput<>nil then FOutput.SetVolume(Master);Inc(FRevision) end;
end;
procedure TGameAssistantVoice.EnsureOutput;
begin
  if FOutput=nil then begin
    FOutput:=TSpeechOutput.Create;FOutput.Configure(FLanguage);FOutput.SetVolume(FMaster);Inc(FRevision);
  end;
end;
procedure TGameAssistantVoice.SetSpeakEnabled(Value:Boolean);
begin
  SyncContext;if FEnabled=Value then Exit;
  FEnabled:=Value;
  if Value then begin EnsureOutput;FOutput.Configure(FLanguage) end else StopSpeech;
  Inc(FRevision);
  UserPreferences.Booleans['assistant_speak_replies']:=Value;SaveUserPreferences;
end;
function TGameAssistantVoice.InputActive:Boolean;
begin
  Result:=FWaitingInput;
  if not Result and FInputCreated then
    Result:=SpeechInput.Snapshot.State in [sisLoading,sisListening,sisFinalizing];
end;
procedure TGameAssistantVoice.StartInput;
begin
  if not Assistant.Connected then Exit;SyncContext;
  if not FConnected then SessionStarted;
  if InputActive then Exit;
  FTranscript:='';FInputError:='';FOutputError:='';FWaitingInput:=True;
  if FOutput<>nil then FCancelBeforeInput:=FOutput.Cancel else FCancelBeforeInput:=0;
  Inc(FRevision);FNextUpdate:=0;Update;
end;
procedure TGameAssistantVoice.StopInput;
begin
  if FWaitingInput then begin CancelInput;Exit end;
  if FInputCreated then SpeechInput.Stop;
  FNextUpdate:=0;Update;
end;
procedure TGameAssistantVoice.CancelInput;
begin
  FWaitingInput:=False;FTranscript:='';FInputError:='';
  if FInputCreated then begin SpeechInput.Cancel;FInput:=SpeechInput.Snapshot end;
  Inc(FRevision);
end;
procedure TGameAssistantVoice.StopSpeech;
begin if FOutput<>nil then FOutput.Cancel;FOutputError:='';Inc(FRevision) end;
procedure TGameAssistantVoice.SessionStarted;
begin
  FConnected:=True;CancelInput;StopSpeech;SyncContext;
  if FEnabled then EnsureOutput;
end;
procedure TGameAssistantVoice.SessionEnded;
begin FConnected:=False;CancelInput;StopSpeech end;
procedure TGameAssistantVoice.ReplyAdded(const Id:Int64;const Text:string);
begin
  SyncContext;
  if not AcceptSpeechReply(Id,FEnabled and Assistant.Connected,InputActive,FLastReplyId) then Exit;
  if FMaster=0 then Exit;
  EnsureOutput;
  if FOutput.Enqueue(Text) then FOutputError:='' else begin
    if FOutput.Status.QueueCount>=SPEECH_QUEUE_LIMIT then FOutputError:='speech_output_queue_full';
  end;
  Inc(FRevision);
end;
procedure TGameAssistantVoice.Update;
var NowMs:QWord;Output:TSpeechOutputStatus;Text:string;
begin
  NowMs:=GetTickCount64;if NowMs<FNextUpdate then Exit;FNextUpdate:=NowMs+100;
  if NowMs>=FNextContext then begin FNextContext:=NowMs+500;SyncContext end;
  if FConnected<>Assistant.Connected then begin
    if Assistant.Connected then SessionStarted else SessionEnded;
  end;
  if FOutput<>nil then begin
    Output:=FOutput.Status;
    if Output.Revision<>FOutputRevision then begin FOutputRevision:=Output.Revision;Inc(FRevision) end;
  end else Output:=Default(TSpeechOutputStatus);
  if FWaitingInput and ((FOutput=nil) or (Output.CancelCompleted>=FCancelBeforeInput)) then begin
    FWaitingInput:=False;FInputCreated:=True;SpeechInput.Start(FLanguage);Inc(FRevision);
  end;
  if FInputCreated then begin
    FInput:=SpeechInput.Snapshot;
    if FInput.Revision<>FInputRevision then begin FInputRevision:=FInput.Revision;Inc(FRevision) end;
    if SpeechInput.PollResult(Text) then begin
      FTranscript:=Text;Inc(FRevision);
    end;
  end;
end;
function TGameAssistantVoice.TakeTranscript(out Text:string):Boolean;
begin
  Text:=FTranscript;Result:=Text<>'';
  if Result then begin FTranscript:='';Inc(FRevision) end;
end;
function TGameAssistantVoice.Snapshot:TJSONObject;
const InputNames:array[TSpeechInputState]of string=('idle','loading','listening','recognizing','error');
var Output:TSpeechOutputStatus;InState,OutState,InError,OutError:string;Available:Boolean;
begin
  Update;InState:=InputNames[FInput.State];if FWaitingInput then InState:='waiting_output';
  InError:=FInput.ErrorCode;if FInputError<>'' then InError:=FInputError;
  OutState:='idle';Output:=Default(TSpeechOutputStatus);
  if FOutput<>nil then begin
    Output:=FOutput.Status;
    if not Output.Ready then OutState:='loading'
    else if not Output.Available then OutState:='unavailable'
    else if Output.Speaking then OutState:='speaking';
  end;
  OutError:=Output.Error;if FOutputError<>'' then OutError:=FOutputError;
  if FEnabled and (FMaster=0) then OutError:='speech_output_muted';
  {$ifdef MSWINDOWS}Available:=True;{$else}Available:=False;{$endif}
  Result:=TJSONObject.Create(['input_state',InState,'input_error',InError,'input_available',Available,
    'input_partial',FInput.PartialText,'level',FInput.Peak,'recording_ms',Int64(FInput.RecordingMilliseconds),
    'output_state',OutState,'output_error',OutError,'output_available',Available and ((FOutput=nil) or not Output.Ready or Output.Available),
    'voice_name',Output.VoiceName,'voice_language',Output.VoiceLanguage,'language_match',Output.LanguageMatch,
    'speak_enabled',FEnabled,'revision',Int64(FRevision)]);
end;
finalization
  FreeAndNil(Instance);
end.
