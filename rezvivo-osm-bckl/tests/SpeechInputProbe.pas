program SpeechInputProbe;
{$mode objfpc}{$H+}{$codepage UTF8}
uses SysUtils, Classes, Windows, ShellApi, fpjson, GameSpeechInput;
var Service: TGameSpeechInputService; S: TSpeechInputSnapshot;
  Started, NowTick: QWord; Text: string;
  SeenLoading, SeenListening, Cancelled: Boolean; J: TJSONObject;
  Args: PPWideChar; ArgCount: Integer;
function Argument(Index: Integer): string;
begin
  if Index < ArgCount then
    Result := UTF8Encode(UnicodeString(PWideChar(PPointer(PtrUInt(Args) + PtrUInt(Index) * SizeOf(Pointer))^)))
  else Result := '';
end;
begin
  { Match the CGE/Lazarus application's UTF-8 string environment. }
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteFileSystemCodePage(CP_UTF8);
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  Args := CommandLineToArgvW(GetCommandLineW, @ArgCount);
  if ParamCount < 3 then begin
    WriteLn('Usage: SpeechInputProbe <speech-assets> <ru|en> <wav-file> [cancel]'); Halt(2);
  end;
  Service := TGameSpeechInputService.Create(Argument(1));
  J := nil;
  try
    Started := GetTickCount64;
    SeenLoading := False; SeenListening := False; Cancelled := Argument(4) = 'cancel';
    if not Service.StartWaveFile(Argument(3), Argument(2)) then
      raise Exception.Create('start rejected');
    if Cancelled then Service.Cancel;
    repeat
      S := Service.Snapshot;
      SeenLoading := SeenLoading or (S.State = sisLoading);
      SeenListening := SeenListening or (S.State = sisListening);
      if S.State in [sisIdle, sisError] then Break;
      if GetTickCount64 - Started > 90000 then begin Service.Cancel; raise Exception.Create('timeout') end;
      Sleep(5);
    until False;
    Service.PollResult(Text);
    NowTick := GetTickCount64;
    J := TJSONObject.Create(['state', SpeechInputStateName(S.State), 'error', S.ErrorCode,
      'text', Text, 'elapsed_ms', Int64(NowTick - Started),
      'audio_ms', Int64(S.RecordingMilliseconds), 'seen_loading', SeenLoading,
      'seen_listening', SeenListening, 'cancelled', Cancelled]);
    if Text <> '' then J.Add('text_first_byte', Ord(Text[1]));
    WriteLn(J.AsJSON);
    if S.State = sisError then ExitCode := 1;
  finally J.Free; Service.Free; LocalFree(HLOCAL(Args)) end;
end.
