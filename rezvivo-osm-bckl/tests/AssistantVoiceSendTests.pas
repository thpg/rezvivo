program AssistantVoiceSendTests;
{$mode objfpc}{$H+}{$codepage UTF8}
uses SysUtils,fpjson,CastleUIControls,CastleFilesUtils,GameMenuTheme,AppSettings,
  GameAssistant,GameAssistantMcp,GameAssistantUI,GameAssistantVoice;
type
  TProbeContainer=class(TCastleContainer)
    function PixelsWidth:Integer;override;
    function PixelsHeight:Integer;override;
  end;
  TProbeAssistant=class(TViewAssistant)
    procedure Recognized(const Text:string);
  end;
function TProbeContainer.PixelsWidth:Integer;
begin Result:=1280 end;
function TProbeContainer.PixelsHeight:Integer;
begin Result:=720 end;
procedure TProbeAssistant.Recognized(const Text:string);
begin SubmitVoiceTranscript(Text) end;
var Checks:Integer;
procedure Check(Value:Boolean;const Why:string);
begin Inc(Checks);if not Value then raise Exception.Create(Why) end;
procedure Run;
const CommandText:string='Поставь тренировку на паузу';
  ResumeText:string='Продолжи тренировку';
var C:TProbeContainer;Chat:TProbeAssistant;Input:TMenuEdit;Token,Draft,LongText:string;
  J:TJSONObject;LastId:Int64;I:Integer;HandleInput:Boolean;
begin
  Check(GetEnvironmentVariable('REZVIVO_TEST_SETTINGS_FILE')<>'','isolated settings required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'','isolated auth required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR')<>'','isolated accounts required');
  ApplicationDataOverride:=IncludeTrailingPathDelimiter(GetCurrentDir)+'data/';
  Settings.AudioMaster:=0;
  SyncAssistantContext(True);Assistant.SetTransportAvailable(True);
  Token:=Assistant.RegisterAgent('Voice regression agent','');
  C:=TProbeContainer.Create(nil);Chat:=TProbeAssistant.Create(C);
  try
    Chat.Open(C);Input:=TMenuEdit(Chat.FindComponent('AssistantMessage'));
    Check(Input<>nil,'real assistant message control created');
    Draft:='Неотправленный текст с клавиатуры';Input.Text:=Draft;
    Chat.Recognized('  '+#9+#10);
    J:=Assistant.Receive(Token,0,0,32);
    try Check(J.Arrays['messages'].Count=0,'silence sends nothing') finally J.Free end;
    Chat.Recognized('  '+CommandText+'  ');
    J:=Assistant.Receive(Token,0,0,32);
    try
      Check(J.Arrays['messages'].Count=1,'voice sends without pressing Send');
      Check(J.Arrays['messages'].Objects[0].Get('text','')=CommandText,
        'only recognized command sent, typed draft remains private');
      LastId:=J.Get('last_id',Int64(0));
    finally J.Free end;
    Check(Input.Text=Draft,'voice leaves typed draft intact');
    Assistant.Acknowledge(Token,LastId);
    for I:=1 to 12 do begin HandleInput:=True;Chat.Update(0.11,HandleInput) end;
    J:=Assistant.Receive(Token,LastId,0,32);
    try Check(J.Arrays['messages'].Count=0,'UI updates do not repeat the command') finally J.Free end;
    for I:=1 to ASSISTANT_PENDING_LIMIT do Assistant.SendUserMessage('queued '+IntToStr(I));
    Chat.Recognized(ResumeText);
    Check(Input.Text=Draft+#10+ResumeText,'queue failure preserves voice and typed text');
    J:=Assistant.Receive(Token,LastId,0,32);
    try
      Check(J.Arrays['messages'].Count=ASSISTANT_PENDING_LIMIT,'queue limit is respected');
      LastId:=J.Get('last_id',Int64(0));
    finally J.Free end;
    Assistant.Acknowledge(Token,LastId);
    for I:=1 to 12 do begin HandleInput:=True;Chat.Update(0.11,HandleInput) end;
    J:=Assistant.Receive(Token,LastId,0,32);
    try Check(J.Arrays['messages'].Count=0,'failed command is not retried automatically') finally J.Free end;
    Input.Text:=Draft;LongText:=StringOfChar('x',ASSISTANT_TEXT_LIMIT+1);
    Chat.Recognized(LongText);
    Check(Input.Text=Draft+#10+LongText,'overlong recognition is preserved without truncation');
    J:=Assistant.Receive(Token,LastId,0,32);
    try Check(J.Arrays['messages'].Count=0,'overlong recognition is not sent') finally J.Free end;
    Input.Text:=Draft;Chat.Close;Chat.Recognized('late closed result');
    Check(Input.Text=Draft,'closing discards late recognition');
    Chat.Open(C);Assistant.Disconnect;Chat.Recognized('late disconnected result');
    Check(Input.Text=Draft,'disconnect discards late recognition');
  finally C.Free;Assistant.SetTransportAvailable(False);ShutdownAssistantVoice end;
end;
begin Run;WriteLn('PASS ',Checks) end.
