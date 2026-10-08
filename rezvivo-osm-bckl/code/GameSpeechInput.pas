unit GameSpeechInput;
{$mode objfpc}{$H+}{$codepage UTF8}
{ Local push-to-talk input. No network, recording files, render work or eager
  model loading. A single worker owns the microphone, Vosk and bounded buffers.
  Vosk C API: https://github.com/alphacep/vosk-api/blob/master/src/vosk_api.h }
interface

uses Classes, SysUtils, SyncObjs;

const
  SPEECH_SAMPLE_RATE = 16000;
  SPEECH_MAX_SECONDS = 45;
  SPEECH_TEXT_LIMIT = 4096;

type
  TSpeechInputState = (sisIdle, sisLoading, sisListening, sisFinalizing, sisError);
  TSpeechInputSnapshot = record
    State: TSpeechInputState;
    Revision: QWord;
    Language, PartialText, ErrorCode: string;
    RecordingMilliseconds: QWord;
    Peak: Single;
  end;

  TGameSpeechInputService = class
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FWorker: TThread;
    FAssetRoot: string;
    FSnapshot: TSpeechInputSnapshot;
    FBusy, FPending, FStopRequested, FCancelled, FClosing: Boolean;
    FWaveFile, FResult: string;
    FResultReady: Boolean;
    function StartRequest(const Language, WaveFile: string): Boolean;
    function Interrupted(out StopRequested: Boolean): Boolean;
    procedure Publish(State: TSpeechInputState; const Partial: string;
      Milliseconds: QWord; Peak: Single);
    procedure Complete(const Text, ErrorCode: string);
  public
    { AssetRoot is a filesystem directory, normally <exe>/data/speech. }
    constructor Create(const AssetRoot: string = '');
    destructor Destroy; override;
    function Start(const Language: string): Boolean;
    procedure Stop;   { asynchronous: drain captured audio and finish text }
    procedure Cancel; { asynchronous: discard audio/text, release microphone }
    function Snapshot: TSpeechInputSnapshot;
    function PollResult(out Text: string): Boolean;
    { Deterministic test input, not exposed in game UI/MCP. Reads an existing
      mono PCM16 16kHz WAV using exactly the live recognizer/streaming path.
      Never opens a microphone or writes an audio file. }
    function StartWaveFile(const FileName, Language: string): Boolean;
  end;

function SpeechInput: TGameSpeechInputService;
procedure ShutdownSpeechInput;
function SpeechInputStateName(State: TSpeechInputState): string;

implementation

uses fpjson, jsonparser
  {$ifdef MSWINDOWS}, Windows, MMSystem{$endif};

type
  ESpeechInputError = class(Exception);
  TVoskModelNew = function(Path: PAnsiChar): Pointer; cdecl;
  TVoskFree = procedure(Value: Pointer); cdecl;
  TVoskRecognizerNew = function(Model: Pointer; SampleRate: Single): Pointer; cdecl;
  TVoskAccept = function(Recognizer: Pointer; Data: PAnsiChar; Size: LongInt): LongInt; cdecl;
  TVoskResult = function(Recognizer: Pointer): PAnsiChar; cdecl;
  TVoskLogLevel = procedure(Level: LongInt); cdecl;
  TOpenBlasThreads = procedure(Count: LongInt); cdecl;

  TVoskSession = class
  private
    FLibrary: THandle;
    FModel, FRecognizer: Pointer;
    FModelFree, FRecognizerFree: TVoskFree;
    FAccept: TVoskAccept;
    FResult, FPartial, FFinal: TVoskResult;
    FCommitted: string;
    FBytes: QWord;
    function ReadText(Value: PAnsiChar; const Key: string): string;
    procedure AppendText(const Value: string);
  public
    constructor Create(const AssetRoot, Language: string);
    destructor Destroy; override;
    function Accept(Data: Pointer; Size: Integer): string;
    function Finish: string;
    property Bytes: QWord read FBytes;
  end;

  TSpeechInputWorker = class(TThread)
  private
    FOwner: TGameSpeechInputService;
    procedure Process(const Language, WaveFile: string);
    procedure ReadWave(Session: TVoskSession; const FileName: string);
    procedure ReadMicrophone(Session: TVoskSession);
    function Feed(Session: TVoskSession; Data: Pointer; Size: Integer): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(Owner: TGameSpeechInputService);
  end;

var Instance: TGameSpeechInputService;
{$ifdef MSWINDOWS}
  { A broken WinMM driver must never retain a pointer to freed buffers. There
    is at most one quarantined 100KiB ring; no further mic session is allowed
    until process exit. Normal stop/reset closes and frees everything. }
  MicrophoneOwner: LongInt; { 0=free, 1=worker, 2=driver failed to release }
  QuarantinedBuffers: Pointer;
  QuarantinedWave: HWAVEIN;
  QuarantinedEvent: THandle;
{$endif}

function SpeechInputStateName(State: TSpeechInputState): string;
begin
  case State of
    sisIdle: Result := 'idle';
    sisLoading: Result := 'loading';
    sisListening: Result := 'listening';
    sisFinalizing: Result := 'finalizing';
    sisError: Result := 'error';
  end;
end;

function SpeechInput: TGameSpeechInputService;
begin
  { Creation and lifetime belong to the main-thread voice facade. }
  if Instance = nil then Instance := TGameSpeechInputService.Create;
  Result := Instance;
end;

procedure ShutdownSpeechInput;
begin
  FreeAndNil(Instance);
end;

constructor TGameSpeechInputService.Create(const AssetRoot: string);
{$ifdef MSWINDOWS}
var ExecutablePath: UnicodeString; N: DWORD;
{$endif}
begin
  inherited Create;
  FLock := SyncObjs.TCriticalSection.Create;
  FWake := SyncObjs.TEvent.Create(nil, False, False, '');
  if AssetRoot = '' then begin
    {$ifdef MSWINDOWS}
    { ParamStr uses the legacy ANSI command line in FPC 3.2; keep installations
      beneath Unicode user/profile paths intact. }
    SetLength(ExecutablePath, 32768);
    N := GetModuleFileNameW(0, PWideChar(ExecutablePath), Length(ExecutablePath));
    SetLength(ExecutablePath, N);
    FAssetRoot := ExtractFilePath(string(UTF8Encode(ExecutablePath)));
    {$else}
    FAssetRoot := ExtractFilePath(ParamStr(0));
    {$endif}
    FAssetRoot := IncludeTrailingPathDelimiter(FAssetRoot) + 'data' + PathDelim + 'speech';
  end
  else FAssetRoot := ExpandFileName(AssetRoot);
  FSnapshot.State := sisIdle;
end;

destructor TGameSpeechInputService.Destroy;
begin
  if FLock <> nil then begin
    FLock.Acquire;
    try
      FClosing := True;
      FCancelled := True;
      FStopRequested := True;
      FResult := '';
      FSnapshot.PartialText := '';
    finally FLock.Release end;
  end;
  if FWake <> nil then FWake.SetEvent;
  { Only application/service destruction waits. Stop and Cancel never join
    a thread on the UI. Native model creation is not interruptible by Vosk. }
  if FWorker <> nil then begin FWorker.WaitFor; FreeAndNil(FWorker) end;
  FreeAndNil(FWake);
  FreeAndNil(FLock);
  inherited;
end;

function TGameSpeechInputService.StartRequest(const Language, WaveFile: string): Boolean;
var Lang: string;
begin
  Result := False;
  Lang := LowerCase(Trim(Language));
  if (Lang = 'ru') or (Copy(Lang, 1, 3) = 'ru-') then Lang := 'ru'
  else if (Lang = 'en') or (Copy(Lang, 1, 3) = 'en-') then Lang := 'en';
  FLock.Acquire;
  try
    if FBusy or FClosing then Exit;
    FResult := '';
    FResultReady := False;
    FSnapshot.PartialText := '';
    FSnapshot.ErrorCode := '';
    FSnapshot.Language := Lang;
    FSnapshot.RecordingMilliseconds := 0;
    FSnapshot.Peak := 0;
    Inc(FSnapshot.Revision);
    if (Lang <> 'ru') and (Lang <> 'en') then begin
      FSnapshot.State := sisError;
      FSnapshot.ErrorCode := 'speech_language_unsupported';
      Exit;
    end;
    FBusy := True;
    FPending := True;
    FStopRequested := False;
    FCancelled := False;
    FWaveFile := WaveFile;
    FSnapshot.State := sisLoading;
    try
      if FWorker = nil then FWorker := TSpeechInputWorker.Create(Self);
    except
      FPending := False;
      FBusy := False;
      FSnapshot.State := sisError;
      FSnapshot.ErrorCode := 'speech_worker_failed';
      Exit;
    end;
    Result := True;
  finally FLock.Release end;
  FWake.SetEvent;
end;

function TGameSpeechInputService.Start(const Language: string): Boolean;
begin Result := StartRequest(Language, '') end;

function TGameSpeechInputService.StartWaveFile(const FileName, Language: string): Boolean;
begin
  if Trim(FileName) = '' then Exit(False);
  Result := StartRequest(Language, ExpandFileName(FileName));
end;

procedure TGameSpeechInputService.Stop;
begin
  FLock.Acquire;
  try
    if not FBusy then Exit;
    FStopRequested := True;
    FSnapshot.State := sisFinalizing;
    Inc(FSnapshot.Revision);
  finally FLock.Release end;
  FWake.SetEvent;
end;

procedure TGameSpeechInputService.Cancel;
begin
  FLock.Acquire;
  try
    FCancelled := True;
    FStopRequested := True;
    FResult := '';
    FResultReady := False;
    FSnapshot.PartialText := '';
    FSnapshot.ErrorCode := '';
    FSnapshot.Peak := 0;
    if FBusy then FSnapshot.State := sisFinalizing else FSnapshot.State := sisIdle;
    Inc(FSnapshot.Revision);
  finally FLock.Release end;
  FWake.SetEvent;
end;

function TGameSpeechInputService.Snapshot: TSpeechInputSnapshot;
begin
  FLock.Acquire;
  try Result := FSnapshot finally FLock.Release end;
end;

function TGameSpeechInputService.PollResult(out Text: string): Boolean;
begin
  FLock.Acquire;
  try
    Result := FResultReady;
    Text := FResult;
    FResultReady := False;
    FResult := '';
  finally FLock.Release end;
end;

function TGameSpeechInputService.Interrupted(out StopRequested: Boolean): Boolean;
begin
  FLock.Acquire;
  try
    Result := FClosing or FCancelled;
    StopRequested := FStopRequested;
  finally FLock.Release end;
end;

procedure TGameSpeechInputService.Publish(State: TSpeechInputState; const Partial: string;
  Milliseconds: QWord; Peak: Single);
begin
  FLock.Acquire;
  try
    if FClosing or FCancelled then Exit;
    if FStopRequested then FSnapshot.State := sisFinalizing else FSnapshot.State := State;
    FSnapshot.PartialText := Partial;
    FSnapshot.RecordingMilliseconds := Milliseconds;
    FSnapshot.Peak := Peak;
    Inc(FSnapshot.Revision);
  finally FLock.Release end;
end;

procedure TGameSpeechInputService.Complete(const Text, ErrorCode: string);
begin
  FLock.Acquire;
  try
    FBusy := False;
    FSnapshot.PartialText := '';
    FSnapshot.Peak := 0;
    FSnapshot.State := sisIdle;
    { Failure to release the hardware must remain visible even after Cancel;
      other cancelled recognition errors/transcripts are intentionally hidden. }
    if not FClosing and (not FCancelled or (ErrorCode = 'speech_microphone_close_failed')) then begin
      FSnapshot.ErrorCode := ErrorCode;
      if ErrorCode <> '' then FSnapshot.State := sisError
      else if Trim(Text) <> '' then begin
        FResult := Trim(Text);
        FResultReady := True;
      end;
    end;
    Inc(FSnapshot.Revision);
  finally FLock.Release end;
end;

{$ifdef MSWINDOWS}
function NativeModelPath(const Path: string): RawByteString;
var W, ShortPath: UnicodeString; Count: DWORD; UsedDefault: BOOL; N: Integer;
  function Encode(const Value: UnicodeString): Boolean;
  begin
    UsedDefault := False;
    N := WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, PWideChar(Value),
      Length(Value), nil, 0, nil, @UsedDefault);
    Result := (N > 0) and not UsedDefault;
    if not Result then Exit;
    SetLength(NativeModelPath, N);
    UsedDefault := False;
    WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, PWideChar(Value),
      Length(Value), PAnsiChar(NativeModelPath), N, nil, @UsedDefault);
    Result := not UsedDefault;
  end;
begin
  { Official MinGW Vosk build uses narrow filesystem streams. UTF-8 paths
    would silently fail on a non-UTF8 Windows ACP. Prefer a lossless ACP path;
    fall back to the existing directory's 8.3 spelling, never change cwd. }
  W := UTF8Decode(Path);
  if GetACP = CP_UTF8 then begin
    Result := UTF8Encode(W);
    Exit;
  end;
  if Encode(W) then Exit;
  Count := GetShortPathNameW(PWideChar(W), nil, 0);
  if Count > 0 then begin
    SetLength(ShortPath, Count);
    Count := GetShortPathNameW(PWideChar(W), PWideChar(ShortPath), Count);
    SetLength(ShortPath, Count);
    if (Count > 0) and Encode(ShortPath) then Exit;
  end;
  raise ESpeechInputError.Create('speech_model_path_encoding');
end;
{$endif}

constructor TVoskSession.Create(const AssetRoot, Language: string);
{$ifdef MSWINDOWS}
const SafeLoadFlags = $00000100 or $00001000; { DLL_LOAD_DIR | DEFAULT_DIRS }
var DllPath, ModelPath: string; W: UnicodeString; NativePath: RawByteString;
  ModelNew: TVoskModelNew; RecognizerNew: TVoskRecognizerNew;
  LogLevel: TVoskLogLevel; LimitThreads: TOpenBlasThreads;
  BlasModule: HMODULE;
  function Symbol(const Name: PAnsiChar): Pointer;
  begin
    Result := GetProcAddress(FLibrary, Name);
    if Result = nil then raise ESpeechInputError.Create('speech_library_incompatible');
  end;
{$endif}
begin
  inherited Create;
  {$ifdef MSWINDOWS}
  DllPath := IncludeTrailingPathDelimiter(AssetRoot) + 'vosk-win64' + PathDelim + 'libvosk.dll';
  ModelPath := IncludeTrailingPathDelimiter(AssetRoot) + 'models' + PathDelim + Language;
  if not FileExists(DllPath) then raise ESpeechInputError.Create('speech_library_missing');
  if not FileExists(IncludeTrailingPathDelimiter(ModelPath) + 'am' + PathDelim + 'final.mdl') then
    raise ESpeechInputError.Create('speech_model_missing');
  W := UTF8Decode(ExpandFileName(DllPath));
  FLibrary := LoadLibraryExW(PWideChar(W), 0, SafeLoadFlags);
  if FLibrary = 0 then raise ESpeechInputError.Create('speech_library_load_failed');
  Pointer(ModelNew) := Symbol('vosk_model_new');
  Pointer(FModelFree) := Symbol('vosk_model_free');
  Pointer(RecognizerNew) := Symbol('vosk_recognizer_new');
  Pointer(FRecognizerFree) := Symbol('vosk_recognizer_free');
  Pointer(FAccept) := Symbol('vosk_recognizer_accept_waveform');
  Pointer(FResult) := Symbol('vosk_recognizer_result');
  Pointer(FPartial) := Symbol('vosk_recognizer_partial_result');
  Pointer(FFinal) := Symbol('vosk_recognizer_final_result');
  Pointer(LogLevel) := Symbol('vosk_set_log_level');
  LogLevel(-1);
  Pointer(LimitThreads) := GetProcAddress(FLibrary, 'openblas_set_num_threads');
  { The official Vosk 0.3.45 Win64 static BLAS exports this documented alias,
    but not openblas_set_num_threads. }
  if not Assigned(LimitThreads) then
    Pointer(LimitThreads) := GetProcAddress(FLibrary, 'goto_set_num_threads');
  if not Assigned(LimitThreads) then begin
    BlasModule := GetModuleHandleW('libopenblas.dll');
    if BlasModule = 0 then BlasModule := GetModuleHandleW('libopenblas64_.dll');
    if BlasModule <> 0 then Pointer(LimitThreads) := GetProcAddress(BlasModule, 'openblas_set_num_threads');
    if (BlasModule <> 0) and not Assigned(LimitThreads) then
      Pointer(LimitThreads) := GetProcAddress(BlasModule, 'goto_set_num_threads');
  end;
  if Assigned(LimitThreads) then LimitThreads(1);
  NativePath := NativeModelPath(ModelPath);
  FModel := ModelNew(PAnsiChar(NativePath));
  if FModel = nil then raise ESpeechInputError.Create('speech_model_load_failed');
  FRecognizer := RecognizerNew(FModel, SPEECH_SAMPLE_RATE);
  if FRecognizer = nil then raise ESpeechInputError.Create('speech_recognizer_failed');
  {$else}
  raise ESpeechInputError.Create('speech_platform_unsupported');
  {$endif}
end;

destructor TVoskSession.Destroy;
begin
  if (FRecognizer <> nil) and Assigned(FRecognizerFree) then FRecognizerFree(FRecognizer);
  if (FModel <> nil) and Assigned(FModelFree) then FModelFree(FModel);
  {$ifdef MSWINDOWS}if FLibrary <> 0 then FreeLibrary(FLibrary);{$endif}
  inherited;
end;

function TVoskSession.ReadText(Value: PAnsiChar; const Key: string): string;
var J: TJSONData; S: string;
begin
  Result := '';
  if Value = nil then raise ESpeechInputError.Create('speech_recognizer_failed');
  { Vosk returns UTF-8 JSON owned by its recognizer; copy before the next call. }
  S := string(Value);
  if Length(S) > 65536 then raise ESpeechInputError.Create('speech_result_too_long');
  J := GetJSON(S);
  try
    if not (J is TJSONObject) then raise ESpeechInputError.Create('speech_invalid_result');
    Result := TJSONObject(J).Get(Key, '');
    if Length(Result) > SPEECH_TEXT_LIMIT then raise ESpeechInputError.Create('speech_result_too_long');
  finally J.Free end;
end;

procedure TVoskSession.AppendText(const Value: string);
begin
  if Trim(Value) = '' then Exit;
  if FCommitted <> '' then FCommitted := FCommitted + ' ';
  FCommitted := FCommitted + Trim(Value);
  if Length(FCommitted) > SPEECH_TEXT_LIMIT then raise ESpeechInputError.Create('speech_result_too_long');
end;

function TVoskSession.Accept(Data: Pointer; Size: Integer): string;
var Code: Integer; Partial: string;
begin
  if (Size <= 0) or Odd(Size) or (Size > 32000) then raise ESpeechInputError.Create('speech_invalid_audio');
  Code := FAccept(FRecognizer, PAnsiChar(Data), Size);
  if Code < 0 then raise ESpeechInputError.Create('speech_recognizer_failed');
  Inc(FBytes, Size);
  if Code > 0 then begin
    AppendText(ReadText(FResult(FRecognizer), 'text'));
    Partial := '';
  end else Partial := ReadText(FPartial(FRecognizer), 'partial');
  Result := FCommitted;
  if Partial <> '' then begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + Partial;
  end;
  { Reject the whole overlong phrase, never split a UTF-8 codepoint in the
    UI's partial text or silently truncate the user's words. }
  if Length(Result) > SPEECH_TEXT_LIMIT then raise ESpeechInputError.Create('speech_result_too_long');
end;

function TVoskSession.Finish: string;
begin
  AppendText(ReadText(FFinal(FRecognizer), 'text'));
  Result := FCommitted;
end;

constructor TSpeechInputWorker.Create(Owner: TGameSpeechInputService);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := Owner;
  Priority := tpLower;
  Start;
end;

procedure TSpeechInputWorker.Execute;
var Pending, Closing: Boolean; Lang, WaveFile: string;
begin
  while True do begin
    FOwner.FWake.WaitFor(High(Cardinal));
    FOwner.FLock.Acquire;
    try
      Closing := FOwner.FClosing;
      Pending := FOwner.FPending;
      FOwner.FPending := False;
      Lang := FOwner.FSnapshot.Language;
      WaveFile := FOwner.FWaveFile;
      FOwner.FWaveFile := '';
    finally FOwner.FLock.Release end;
    if Closing then Exit;
    if Pending then Process(Lang, WaveFile);
  end;
end;

function TSpeechInputWorker.Feed(Session: TVoskSession; Data: Pointer; Size: Integer): Boolean;
var StopRequested: Boolean; Text: string; I, Peak: Integer; P: PSmallInt;
begin
  Result := False;
  if FOwner.Interrupted(StopRequested) then Exit;
  if QWord(Size) + Session.Bytes > QWord(SPEECH_MAX_SECONDS * SPEECH_SAMPLE_RATE * 2) then
    Size := SPEECH_MAX_SECONDS * SPEECH_SAMPLE_RATE * 2 - Session.Bytes;
  if Size <= 0 then Exit;
  Text := Session.Accept(Data, Size);
  Peak := 0;
  P := PSmallInt(Data);
  for I := 0 to (Size div 2) - 1 do begin
    if Abs(Integer(P^)) > Peak then Peak := Abs(Integer(P^));
    Inc(P);
  end;
  FOwner.Publish(sisListening, Text, Session.Bytes * 1000 div (SPEECH_SAMPLE_RATE * 2), Peak / 32768);
  Result := Session.Bytes < QWord(SPEECH_MAX_SECONDS * SPEECH_SAMPLE_RATE * 2);
end;

procedure TSpeechInputWorker.Process(const Language, WaveFile: string);
var Session: TVoskSession; Text, ErrorCode: string; StopRequested: Boolean;
begin
  Session := nil;
  Text := '';
  ErrorCode := '';
  try
    try
      if not FOwner.Interrupted(StopRequested) and not StopRequested then begin
        Session := TVoskSession.Create(FOwner.FAssetRoot, Language);
        if not FOwner.Interrupted(StopRequested) and not StopRequested then begin
          if WaveFile = '' then ReadMicrophone(Session) else ReadWave(Session, WaveFile);
          if not FOwner.Interrupted(StopRequested) then begin
            FOwner.Publish(sisFinalizing, '', Session.Bytes * 1000 div (SPEECH_SAMPLE_RATE * 2), 0);
            Text := Session.Finish;
            if Trim(Text) = '' then ErrorCode := 'speech_no_speech';
          end;
        end;
      end;
    except
      on E: ESpeechInputError do ErrorCode := E.Message;
      on E: Exception do ErrorCode := 'speech_processing_failed';
    end;
  finally Session.Free end;
  { Publish completion only after microphone, decoder, model and DLL have gone. }
  FOwner.Complete(Text, ErrorCode);
end;

procedure TSpeechInputWorker.ReadWave(Session: TVoskSession; const FileName: string);
type TFourCC = array[0..3] of AnsiChar;
var Stream: TFileStream; ID, Kind: TFourCC; ChunkSize, RiffSize: LongWord;
  ChunkEnd, DataOffset, DataSize, Remaining: Int64;
  Format: array[0..15] of Byte; HaveFormat, StopRequested: Boolean;
  Buffer: array[0..3199] of Byte; Count: Integer;
  function WordAt(Index: Integer): Word;
  begin Result := Word(Format[Index]) or (Word(Format[Index + 1]) shl 8) end;
  function DWordAt(Index: Integer): LongWord;
  begin Result := LongWord(WordAt(Index)) or (LongWord(WordAt(Index + 2)) shl 16) end;
begin
  if not FileExists(FileName) then raise ESpeechInputError.Create('speech_audio_missing');
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    if (Stream.Size < 44) or (Stream.Size > 4 * 1024 * 1024) then
      raise ESpeechInputError.Create('speech_invalid_audio');
    Stream.ReadBuffer(ID, 4); Stream.ReadBuffer(RiffSize, 4); Stream.ReadBuffer(Kind, 4);
    if (ID <> 'RIFF') or (Kind <> 'WAVE') or (Int64(RiffSize) + 8 > Stream.Size) then
      raise ESpeechInputError.Create('speech_invalid_audio');
    DataOffset := 0; DataSize := 0; HaveFormat := False;
    while Stream.Position + 8 <= Int64(RiffSize) + 8 do begin
      Stream.ReadBuffer(ID, 4); Stream.ReadBuffer(ChunkSize, 4);
      ChunkEnd := Stream.Position + Int64(ChunkSize);
      if ChunkEnd > Int64(RiffSize) + 8 then raise ESpeechInputError.Create('speech_invalid_audio');
      if ID = 'fmt ' then begin
        if (ChunkSize < 16) or HaveFormat then raise ESpeechInputError.Create('speech_invalid_audio');
        Stream.ReadBuffer(Format, SizeOf(Format));
        HaveFormat := True;
      end else if ID = 'data' then begin
        if DataOffset <> 0 then raise ESpeechInputError.Create('speech_invalid_audio');
        DataOffset := Stream.Position; DataSize := ChunkSize;
      end;
      Stream.Position := ChunkEnd + (ChunkSize and 1);
    end;
    if not HaveFormat or (DataOffset = 0) or (DataSize = 0) or Odd(DataSize) then
      raise ESpeechInputError.Create('speech_invalid_audio');
    if (WordAt(0) <> 1) or (WordAt(2) <> 1) or (DWordAt(4) <> SPEECH_SAMPLE_RATE) or
      (DWordAt(8) <> SPEECH_SAMPLE_RATE * 2) or (WordAt(12) <> 2) or (WordAt(14) <> 16) then
      raise ESpeechInputError.Create('speech_audio_format_unsupported');
    if DataSize > SPEECH_MAX_SECONDS * SPEECH_SAMPLE_RATE * 2 then
      raise ESpeechInputError.Create('speech_audio_too_long');
    Stream.Position := DataOffset; Remaining := DataSize;
    FOwner.Publish(sisListening, '', 0, 0);
    while Remaining > 0 do begin
      if FOwner.Interrupted(StopRequested) or StopRequested then Break;
      Count := SizeOf(Buffer); if Remaining < Count then Count := Remaining;
      Stream.ReadBuffer(Buffer, Count); Dec(Remaining, Count);
      if not Feed(Session, @Buffer[0], Count) then Break;
    end;
  finally
    FillChar(Buffer, SizeOf(Buffer), 0);
    Stream.Free;
  end;
end;

procedure TSpeechInputWorker.ReadMicrophone(Session: TVoskSession);
{$ifdef MSWINDOWS}
const BufferCount = 32; BufferBytes = 3200; { bounded 3.2-second ring, 100 KiB }
type TCaptureBuffer = record
    Header: TWAVEHDR;
    Data: array[0..BufferBytes - 1] of Byte;
    Prepared: Boolean;
  end;
  TCaptureBuffers = array[0..BufferCount - 1] of TCaptureBuffer;
  PCaptureBuffers = ^TCaptureBuffers;
var Buffers: PCaptureBuffers;
  Wave: HWAVEIN; WaveEvent: THandle; Format: TWAVEFORMATEX;
  Code: MMRESULT; I, NextBuffer, DoneCount, Pass, Retry, OwnerState: Integer;
  StopRequested, Cancelled, Draining, LimitReached: Boolean;
  StartedAt: QWord;
  procedure Check(Value: MMRESULT; const Operation: string);
  begin
    if Value = MMSYSERR_NOERROR then Exit;
    if Value = MMSYSERR_ALLOCATED then raise ESpeechInputError.Create('speech_microphone_busy');
    if (Value = MMSYSERR_BADDEVICEID) or (Value = MMSYSERR_NODRIVER) then
      raise ESpeechInputError.Create('speech_microphone_missing');
    if Value = WAVERR_BADFORMAT then raise ESpeechInputError.Create('speech_microphone_format');
    raise ESpeechInputError.Create(Operation);
  end;
{$endif}
begin
  {$ifdef MSWINDOWS}
  if waveInGetNumDevs = 0 then raise ESpeechInputError.Create('speech_microphone_missing');
  OwnerState := InterlockedCompareExchange(MicrophoneOwner, 1, 0);
  if OwnerState = 2 then raise ESpeechInputError.Create('speech_microphone_close_failed');
  if OwnerState <> 0 then raise ESpeechInputError.Create('speech_microphone_busy');
  Buffers := nil;
  FillChar(Format, SizeOf(Format), 0);
  Format.wFormatTag := WAVE_FORMAT_PCM;
  Format.nChannels := 1;
  Format.nSamplesPerSec := SPEECH_SAMPLE_RATE;
  Format.wBitsPerSample := 16;
  Format.nBlockAlign := 2;
  Format.nAvgBytesPerSec := SPEECH_SAMPLE_RATE * 2;
  Wave := 0;
  WaveEvent := 0;
  try
    New(Buffers);
    FillChar(Buffers^, SizeOf(Buffers^), 0);
    WaveEvent := CreateEvent(nil, False, False, nil);
    if WaveEvent = 0 then raise ESpeechInputError.Create('speech_microphone_failed');
    Check(waveInOpen(@Wave, WAVE_MAPPER, @Format, DWORD_PTR(WaveEvent), 0, CALLBACK_EVENT),
      'speech_microphone_denied');
    for I := 0 to High(Buffers^) do begin
      Buffers^[I].Header.lpData := PAnsiChar(@Buffers^[I].Data[0]);
      Buffers^[I].Header.dwBufferLength := BufferBytes;
      Check(waveInPrepareHeader(Wave, @Buffers^[I].Header, SizeOf(TWAVEHDR)), 'speech_microphone_failed');
      Buffers^[I].Prepared := True;
      Check(waveInAddBuffer(Wave, @Buffers^[I].Header, SizeOf(TWAVEHDR)), 'speech_microphone_failed');
    end;
    Cancelled := FOwner.Interrupted(StopRequested);
    if Cancelled or StopRequested then Exit;
    Check(waveInStart(Wave), 'speech_microphone_failed');
    StartedAt := GetTickCount64;
    NextBuffer := 0; Draining := False; LimitReached := False;
    FOwner.Publish(sisListening, '', 0, 0);
    repeat
      Cancelled := FOwner.Interrupted(StopRequested);
      if Cancelled then Break;
      if (GetTickCount64 - StartedAt >= SPEECH_MAX_SECONDS * 1000) or LimitReached then
        StopRequested := True;
      if StopRequested and not Draining then begin
        { Reset stops hardware immediately and returns even the partial buffer;
          drain in ring order once, preserving the final syllable on button-up. }
        Check(waveInReset(Wave), 'speech_microphone_failed');
        Draining := True;
      end;
      DoneCount := 0;
      for I := 0 to High(Buffers^) do
        if Buffers^[I].Header.dwFlags and WHDR_DONE <> 0 then Inc(DoneCount);
      if (DoneCount = BufferCount) and not Draining then
        raise ESpeechInputError.Create('speech_audio_overrun');
      Pass := 0;
      while (Pass < BufferCount) and
        (Buffers^[NextBuffer].Header.dwFlags and WHDR_DONE <> 0) do begin
        if Buffers^[NextBuffer].Header.dwBytesRecorded > BufferBytes then
          raise ESpeechInputError.Create('speech_invalid_audio');
        if (Buffers^[NextBuffer].Header.dwBytesRecorded > 0) and not LimitReached then
          LimitReached := not Feed(Session, @Buffers^[NextBuffer].Data[0],
            Buffers^[NextBuffer].Header.dwBytesRecorded);
        if FOwner.Interrupted(StopRequested) then Break;
        if not Draining then begin
          Buffers^[NextBuffer].Header.dwBytesRecorded := 0;
          Check(waveInAddBuffer(Wave, @Buffers^[NextBuffer].Header, SizeOf(TWAVEHDR)), 'speech_microphone_failed');
        end;
        NextBuffer := (NextBuffer + 1) mod BufferCount;
        Inc(Pass);
        if LimitReached and not Draining then Break;
      end;
      if Draining then Break;
      WaitForSingleObject(WaveEvent, 25); { stop/cancel observed within 25ms + one decode chunk }
    until False;
  finally
    if Wave <> 0 then begin
      { Most drivers complete this in the first pass. Never free a ring or
        close its callback event until the device confirms release. Retry is
        bounded and only on this worker, including unplug/driver failures. }
      for Retry := 0 to 19 do begin
        waveInStop(Wave);
        waveInReset(Wave);
        if Buffers <> nil then
          for I := 0 to High(Buffers^) do
            if Buffers^[I].Prepared then begin
              Code := waveInUnprepareHeader(Wave, @Buffers^[I].Header, SizeOf(TWAVEHDR));
              if Code = MMSYSERR_NOERROR then Buffers^[I].Prepared := False;
            end;
        Code := waveInClose(Wave);
        if Code = MMSYSERR_NOERROR then begin Wave := 0; Break end;
        Sleep(10);
      end;
    end;
    if Wave = 0 then begin
      if WaveEvent <> 0 then CloseHandle(WaveEvent);
      if Buffers <> nil then begin
        FillChar(Buffers^, SizeOf(Buffers^), 0);
        Dispose(Buffers);
      end;
      InterlockedExchange(MicrophoneOwner, 0);
    end else begin
      QuarantinedBuffers := Buffers;
      QuarantinedWave := Wave;
      QuarantinedEvent := WaveEvent;
      InterlockedExchange(MicrophoneOwner, 2);
      raise ESpeechInputError.Create('speech_microphone_close_failed');
    end;
  end;
  {$else}
  raise ESpeechInputError.Create('speech_platform_unsupported');
  {$endif}
end;

finalization
  ShutdownSpeechInput;
end.
