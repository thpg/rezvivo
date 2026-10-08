program SpeechOutputTests;
{$mode objfpc}{$H+}{$codepage UTF8}
uses Classes,SysUtils,GameSpeechOutput;
var Checks:Integer;
procedure Check(B:Boolean;const Why:string);
begin Inc(Checks);if not B then raise Exception.Create(Why) end;
function WaitReady(S:TSpeechOutput):TSpeechOutputStatus;
var Deadline:QWord;
begin
  Deadline:=GetTickCount64+10000;
  repeat Result:=S.Status;if Result.Ready then Exit;Sleep(10) until GetTickCount64>=Deadline;
  raise Exception.Create('SAPI startup timed out');
end;
function WaitIdle(S:TSpeechOutput):TSpeechOutputStatus;
var Deadline:QWord;
begin
  Deadline:=GetTickCount64+30000;
  repeat
    Result:=S.Status;
    if Result.Ready and not Result.Available then raise Exception.Create(Result.Error);
    if not Result.Speaking and (Result.QueueCount=0) then Exit;
    Sleep(10);
  until GetTickCount64>=Deadline;
  raise Exception.Create('SAPI synthesis timed out');
end;
procedure SaveWave(const FileName:string;const PCM:TBytes);
var F:TFileStream;N:LongWord;W:Word;
  procedure Four(const S:AnsiString);begin F.WriteBuffer(S[1],4) end;
  procedure U32(V:LongWord);begin F.WriteBuffer(V,4) end;
  procedure U16(V:Word);begin F.WriteBuffer(V,2) end;
begin
  ForceDirectories(ExtractFilePath(FileName));F:=TFileStream.Create(FileName,fmCreate);
  try
    N:=Length(PCM);Four('RIFF');U32(N+36);Four('WAVE');Four('fmt ');U32(16);
    U16(1);U16(1);U32(16000);U32(32000);U16(2);U16(16);Four('data');U32(N);
    if N>0 then F.WriteBuffer(PCM[0],N);
  finally F.Free end;
end;
procedure Fixture(S:TSpeechOutput;const Language,Text,FileName:string);
var Status:TSpeechOutputStatus;PCM:TBytes;I:Integer;NonZero:Boolean;
begin
  S.Configure(Language);Status:=WaitReady(S);
  Check(Status.Available,'native SAPI voice available: '+Status.Error);
  Check(Status.LanguageMatch,'native language voice installed: '+Language);
  Writeln(Language,': ',Status.VoiceName,' [',Status.VoiceLanguage,']');
  Check(S.Enqueue(Text),'fixture queued');Status:=WaitIdle(S);PCM:=S.CopyTestPCM;
  Check(Length(PCM)>32000,'speech exceeds one second');
  Check((Length(PCM) mod 2)=0,'PCM16 alignment');NonZero:=False;
  for I:=0 to High(PCM) do if PCM[I]<>0 then begin NonZero:=True;Break end;
  Check(NonZero,'real synthesis, not silence');SaveWave(FileName,PCM);
end;
procedure Run;
var S:TSpeechOutput;St:TSpeechOutputStatus;CancelID,Deadline:QWord;I:Integer;U:UnicodeString;
begin
  U:=SpeechPlainText(StringOfChar('x',SPEECH_TEXT_LIMIT+30));Check(Length(U)=SPEECH_TEXT_LIMIT,'spoken length bounded');
  Check(SpeechPlainText('<speak>literal</speak>')='<speak>literal</speak>','plain text preserved for SAPI no-XML flag');
  Check(SpeechPlainText(' a'+#0+#9+'b ')='a  b','controls removed');
  S:=TSpeechOutput.Create(True);
  try
    Fixture(S,'ru','Начни интервальную тренировку. Уменьши мощность на пять ватт. Какой сейчас пульс?',
      ExtractFilePath(ParamStr(0))+'speech-ru.wav');
    Fixture(S,'en','Start my interval workout. Reduce the power by five watts. What is my heart rate?',
      ExtractFilePath(ParamStr(0))+'speech-en.wav');
    S.Configure('zz');St:=WaitReady(S);Check(not St.LanguageMatch,'unsupported language is explicit');
    Check(St.Error='speech_voice_language_unavailable','no false promise of installed language');
    Check(not S.Enqueue('Unavailable language'),'wrong-language speech not queued');
    S.Configure('en');St:=WaitReady(S);
    for I:=1 to SPEECH_QUEUE_LIMIT+2 do S.Enqueue(StringOfChar('x',SPEECH_TEXT_LIMIT));
    St:=S.Status;Check(St.QueueCount<=SPEECH_QUEUE_LIMIT,'bounded queue');CancelID:=S.Cancel;
    Deadline:=GetTickCount64+3000;
    repeat St:=S.Status;if St.CancelCompleted>=CancelID then Break;Sleep(10) until GetTickCount64>=Deadline;
    Check(St.CancelCompleted>=CancelID,'asynchronous cancellation acknowledged');
    Check((not St.Speaking) and (St.QueueCount=0),'cancel drains active and queued speech');
    Check(S.Enqueue('After cancellation'),'new speech after cancellation works');St:=WaitIdle(S);
    S.SetVolume(0);CancelID:=S.Cancel;Deadline:=GetTickCount64+3000;
    repeat St:=S.Status;if St.CancelCompleted>=CancelID then Break;Sleep(10) until GetTickCount64>=Deadline;
    Check(St.CancelCompleted>=CancelID,'mute cancellation acknowledged');
  finally S.Free end;
end;
begin Run;Writeln('PASS ',Checks) end.
