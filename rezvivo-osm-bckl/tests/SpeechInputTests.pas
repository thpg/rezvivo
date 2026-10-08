program SpeechInputTests;
{$mode objfpc}{$H+}{$codepage UTF8}
uses SysUtils, Classes, Windows, fpjson, GameSpeechInput;
var Service: TGameSpeechInputService; Assets, Fixtures, OutputDir: string;
  Count: Integer; Report: TJSONObject; Results: TJSONArray;

procedure Check(Value: Boolean; const Name: string);
begin
  if not Value then raise Exception.Create('FAIL: ' + Name);
  Inc(Count); Results.Add(Name);
end;

function WaitIdle: TSpeechInputSnapshot;
var Started: QWord;
begin
  Started := GetTickCount64;
  repeat
    Result := Service.Snapshot;
    if Result.State in [sisIdle, sisError] then Exit;
    if GetTickCount64 - Started > 60000 then raise Exception.Create('test timeout');
    Sleep(2);
  until False;
end;

procedure WriteWave(const Name: string; Seconds: Integer; Channels: Word);
var Stream: TFileStream; Data: array of Byte; N: LongWord; W: Word;
  procedure Tag(const S: AnsiString);
  begin Stream.WriteBuffer(S[1], 4) end;
begin
  Stream := TFileStream.Create(Name, fmCreate);
  try
    N := Seconds * 16000 * Channels * 2;
    SetLength(Data, N);
    FillChar(Data[0], N, 0);
    Tag('RIFF'); Inc(N, 36); Stream.WriteBuffer(N, 4); Tag('WAVE'); Tag('fmt ');
    N := 16; Stream.WriteBuffer(N, 4);
    W := 1; Stream.WriteBuffer(W, 2); Stream.WriteBuffer(Channels, 2);
    N := 16000; Stream.WriteBuffer(N, 4);
    N := 16000 * Channels * 2; Stream.WriteBuffer(N, 4);
    W := Channels * 2; Stream.WriteBuffer(W, 2);
    W := 16; Stream.WriteBuffer(W, 2);
    Tag('data'); N := Length(Data); Stream.WriteBuffer(N, 4); Stream.WriteBuffer(Data[0], N);
  finally Stream.Free end;
end;

procedure ExpectError(const FileName, ErrorCode: string);
var S: TSpeechInputSnapshot; Text: string;
begin
  Check(Service.StartWaveFile(FileName, 'en'), 'start ' + ErrorCode);
  S := WaitIdle;
  Check((S.State = sisError) and (S.ErrorCode = ErrorCode), ErrorCode);
  Check(not Service.PollResult(Text), 'no transcript after ' + ErrorCode);
  Check(GetModuleHandleW('libvosk.dll') = 0, 'release Vosk after ' + ErrorCode);
end;

procedure Recognize(const Language, ExpectedA, ExpectedB: string);
var S: TSpeechInputSnapshot; Text: string;
begin
  Check(Service.StartWaveFile(Fixtures + 'speech-' + Language + '.wav', Language), 'start ' + Language);
  Check(not Service.StartWaveFile(Fixtures + 'speech-en.wav', 'en'), 'reject concurrent request');
  S := WaitIdle;
  Check((S.State = sisIdle) and (S.ErrorCode = ''), 'successful ' + Language + ' decode');
  Check(Service.PollResult(Text), 'one result ' + Language);
  Check((Pos(ExpectedA, Text) > 0) and (Pos(ExpectedB, Text) > 0), 'known synthetic words ' + Language);
  Report.Add('recognized_' + Language, Text);
  Check(not Service.PollResult(Text) and (Text = ''), 'consume exactly once ' + Language);
  Check(GetModuleHandleW('libvosk.dll') = 0, 'release Vosk after ' + Language);
  Check(S.RecordingMilliseconds > 6000, 'processed full WAV ' + Language);
end;

var S: TSpeechInputSnapshot; Text, Path: string; Started, Elapsed: QWord;
  F: TFileStream; ReportStream: TStringStream;
begin
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteFileSystemCodePage(CP_UTF8);
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  if ParamCount <> 3 then begin WriteLn('SpeechInputTests <assets> <fixtures> <out>'); Halt(2) end;
  Assets := ParamStr(1); Fixtures := IncludeTrailingPathDelimiter(ParamStr(2));
  OutputDir := IncludeTrailingPathDelimiter(ParamStr(3)); ForceDirectories(OutputDir);
  Report := TJSONObject.Create; Results := TJSONArray.Create; Report.Add('checks', Results);
  Service := TGameSpeechInputService.Create(Assets);
  try
    Check(Service.Snapshot.State = sisIdle, 'creation idle');
    Check(GetModuleHandleW('libvosk.dll') = 0, 'no model/DLL loaded on construction');
    Check(not Service.Start('fr'), 'unsupported language rejected without worker');
    Check(Service.Snapshot.ErrorCode = 'speech_language_unsupported', 'unsupported language code');
    Recognize('en', 'interval workout', 'heart rate');
    Recognize('ru', 'мощность', 'пульс');

    Started := GetTickCount64;
    Check(Service.StartWaveFile(Fixtures + 'speech-en.wav', 'en'), 'start cancellation');
    Service.Cancel;
    Elapsed := GetTickCount64 - Started;
    Check(Elapsed < 100, 'start/cancel returns without waiting for model');
    S := WaitIdle;
    Check((S.State = sisIdle) and (S.PartialText = '') and (S.ErrorCode = ''), 'cancel clears partial/error');
    Check(not Service.PollResult(Text), 'cancel discards final result');
    Check(GetModuleHandleW('libvosk.dll') = 0, 'cancel releases DLL');

    Check(Service.StartWaveFile(Fixtures + 'speech-en.wav', 'en'), 'start cancel during decoding');
    Started := GetTickCount64;
    repeat
      S := Service.Snapshot;
      if (S.RecordingMilliseconds >= 300) or (S.State in [sisIdle, sisError]) then Break;
      if GetTickCount64 - Started > 30000 then raise Exception.Create('decode start timeout');
      Sleep(1);
    until False;
    Check(S.State = sisListening, 'cancel while decoder active');
    Service.Cancel; S := WaitIdle;
    Check(not Service.PollResult(Text) and (S.PartialText = ''), 'in-flight text discarded');
    Check(GetModuleHandleW('libvosk.dll') = 0, 'in-flight model released');

    WriteWave(OutputDir + 'silence.wav', 1, 1);
    WriteWave(OutputDir + 'stereo.wav', 1, 2);
    WriteWave(OutputDir + 'long.wav', SPEECH_MAX_SECONDS + 1, 1);
    F := TFileStream.Create(OutputDir + 'broken.wav', fmCreate);
    try F.WriteBuffer(Count, SizeOf(Count)) finally F.Free end;
    ExpectError(OutputDir + 'silence.wav', 'speech_no_speech');
    ExpectError(OutputDir + 'stereo.wav', 'speech_audio_format_unsupported');
    ExpectError(OutputDir + 'long.wav', 'speech_audio_too_long');
    ExpectError(OutputDir + 'broken.wav', 'speech_invalid_audio');
    ExpectError(OutputDir + 'not-there.wav', 'speech_audio_missing');
    Service.Cancel;
    Check(Service.Snapshot.State = sisIdle, 'dismiss error with cancel');
    FreeAndNil(Service);

    Path := OutputDir + 'missing-assets-' + IntToStr(GetTickCount64);
    Service := TGameSpeechInputService.Create(Path);
    ExpectError(Fixtures + 'speech-en.wav', 'speech_library_missing');
    FreeAndNil(Service);
    ForceDirectories(Path + PathDelim + 'vosk-win64');
    F := TFileStream.Create(Path + PathDelim + 'vosk-win64' + PathDelim + 'libvosk.dll', fmCreate);
    F.Free;
    Service := TGameSpeechInputService.Create(Path);
    ExpectError(Fixtures + 'speech-en.wav', 'speech_model_missing');
    FreeAndNil(Service);

    Service := TGameSpeechInputService.Create(Assets);
    Check(Service.StartWaveFile(Fixtures + 'speech-en.wav', 'en'), 'start before shutdown');
    FreeAndNil(Service);
    Check(GetModuleHandleW('libvosk.dll') = 0, 'destruction joins worker and unloads DLL');
    Report.Add('passed', Count);
    ReportStream := TStringStream.Create(Report.FormatJSON);
    try ReportStream.SaveToFile(OutputDir + 'report.json') finally ReportStream.Free end;
    WriteLn('PASS ', Count);
  finally Service.Free; Report.Free end;
end.
