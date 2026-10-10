{ GameSensorLog — continuous sensor data journal in CSV format.

  Creates a file in sessions/ folder on first valid data.
  Filename: session_YYYY-MM-DD_HH-MM-SS.csv
  Writes each record as a CSV line, flushes every ~1 second.
  Registers ExitProc to flush+close on crash. }
unit GameSensorLog;

{$mode objfpc}{$H+}

interface

uses
  TrainerData, GameJournalWriter, GameActivitySource;

type
  { Запись сессии прочитанная из CSV — используется FIT-writer'ом и
    очередью загрузки заездов. Совпадает с колонками CSV-журнала
    плюс абсолютный TimestampUtcUnix, восстановленный из имени файла +
    ElapsedSec. Поля без значения (которых не было в источнике)
    помечены через сигнальные значения: HeartRate=0, Power=$FFFF.
    Нулевая мощность означает настоящий накат. }
  TSensorSessionRecord = record
    TimestampUtcUnix: Int64;     { UTC старта + время поездки; CSV Timestamp сохраняет wall time }
    LocalTimestamp:TDateTime;    { Actual wall date/time, only present in new ISO CSV rows }
    HasLocalTimestamp:Boolean;
    ElapsedSec:       Double;
    Power:            Word;       { Вт }
    Cadence:          Word;       { об/мин }
    HeartRate:        Byte;       { уд/мин }
    SpeedKmh:         Single;
    DistanceM:        Cardinal;
    SlopePct:         Single;
    HasSessionState:  Boolean;
    TimerActive:      Boolean;
    Lap:             Integer;
    TargetWatts:      Word;
    SourceFlags:      Byte; { cumulative provenance, survives crash/resume }
  end;
  TSensorSessionRecordArray = array of TSensorSessionRecord;

  TSensorLog = class
  private
    FWriter: TJournalWriter;
    FOpened: Boolean;
    FFileName: string;
    FOwnerKey:string;
    FLocalError:string;
    FSessionDir: string;
    FStartTime: TDateTime;
    FLinesSinceFlush: Integer;
    FTotalLines: Integer;
    FLastWasZero: Boolean;
    { Thinning: пропускаем записи если значимые поля не изменились с
      предыдущей. Раз в секунду пишем «keep-alive» строку даже без
      изменений, чтобы FIT-парсер видел паузу как реальные секунды,
      а не как пропуск данных. }
    FHasLast: Boolean;
    FLastPower: Word;
    FLastCadence: Byte;
    FLastSpeed: Single;
    FLastHR: Byte;
    FLastDistance: LongWord;
    FLastWriteTime: TDateTime;
    FLastWriteTick,FStartTick: QWord;
    FTimerActive,FLastTimerActive: Boolean;
    FLap,FLastLap,FTarget,FLastTarget: Integer;
    FResumeElapsed,FLastElapsed: Double;
    FLastData:TTrainerDataRecord;
    FLastSlope:Single;
    FRecordingEnabled,FRecordingResumePending:Boolean;
    FActivityClock:Boolean;
    FClockElapsed:Double;
    FHasFrameData:Boolean;
    FFrameData:TTrainerDataRecord;
    FFrameSlope:Single;
    FSourceFlags,FLastSourceFlags:Byte;
    procedure SetRecordingEnabled(Value:Boolean);
    function GetError:String;
    function GetElapsed:Double;
    procedure OpenFile;
    procedure WriteHeader;
    procedure WriteData(const Data:TTrainerDataRecord;ASlope:Single;Force:Boolean);
    procedure FlushFrame;
    class function ReadSession(const AFileName:string;TailOnly:Boolean):TSensorSessionRecordArray;
  public
    constructor Create(const ASessionDir: string = 'sessions');
    destructor Destroy; override;

    { Log one sensor data record. Opens file on first call.
      ASlope is game route slope in percent (not from sensor). }
    procedure LogData(const Data: TTrainerDataRecord; ASlope: Single);
    { The ride owns elapsed time. Wall Timestamp and writer durability still
      use real time. LogFrame integrates precisely the same interval and power
      snapshot as activity/daily accounting, including slow/fast simulation. }
    procedure UseActivityClock;
    procedure LogFrame(const Data:TTrainerDataRecord;ASlope:Single;Seconds:Double;
      SourceFlags:Byte=ActivitySourceUnknown);

    { Flush buffered data to disk immediately. }
    procedure Flush;

    { Close journal. Safe to call multiple times. }
    procedure Close(Completed:Boolean=True);
    procedure Resume(const Journal:String;Elapsed:Double);
    procedure SetSessionState(TimerActive:Boolean;Lap,TargetWatts:Integer);
    procedure SaveCheckpoint(const Path,Json:String);
    property ErrorText:String read GetError;
    property JournalElapsed:Double read GetElapsed;
    property RecordingEnabled:Boolean read FRecordingEnabled write SetRecordingEnabled;
    property OwnerKey:String read FOwnerKey write FOwnerKey;

    property FileName: string read FFileName;
    property TotalLines: Integer read FTotalLines;
    property IsOpen: Boolean read FOpened;

    { ── Reverse-direction API: чтение CSV обратно в записи ─────────

      Используется FIT-writer'ом и очередью загрузки. В случае
      невалидного формата возвращает nil/empty array, ошибки в лог.
      Имя файла должно соответствовать конвенции
      session_YYYY-MM-DD_HH-MM-SS.csv (только так извлекается
      абсолютная отметка времени старта). }
    class function LoadSession(const AFileName: string): TSensorSessionRecordArray;
    class function CanUploadIntervals(const Rows:TSensorSessionRecordArray):Boolean;

    { Извлечь абсолютное время старта из имени файла session_*.csv.
      Возвращает 0 при невалидном формате. }
    class function ParseStartTimeFromName(const AFileName: string): Int64;

    { Полный путь к директории, где TSensorLog пишет CSV. Та же
      функция используется RideUploadQueue для скана оставшихся
      сессий. Возвращает путь без trailing-слэша. }
    class function SessionDir: string;
  end;

{ Global instance — created lazily, flushed+closed on exit }
function SensorLog: TSensorLog;

implementation


uses
  AppRuntimePaths, SysUtils, Classes, DateUtils, Math, DebugLog;

const
  CSVSep = ',';

var
  GSensorLog: TSensorLog = nil;
  GOldExitProc: Pointer = nil;

{ ── Exit handler: flush and close on crash ── }
procedure SensorLogExitProc;
begin
  if Assigned(GSensorLog) then
  begin
    try
      GSensorLog.Flush;
      GSensorLog.Close(False);
    except
      { swallow — we're crashing }
    end;
    FreeAndNil(GSensorLog);
  end;
  ExitProc := GOldExitProc;
end;

function SensorLog: TSensorLog;
begin
  if not Assigned(GSensorLog) then
  begin
    GSensorLog := TSensorLog.Create;
    GOldExitProc := ExitProc;
    ExitProc := @SensorLogExitProc;
  end;
  Result := GSensorLog;
end;

{ ══════════════════════════════════════════════════════════════════ }

constructor TSensorLog.Create(const ASessionDir: string);
begin
  inherited Create;
  FOpened := False;
  FRecordingEnabled:=True;
  FLinesSinceFlush := 0;
  FTotalLines := 0;
  FLastWasZero := False;
  FHasLast := False;
  FLastWriteTime := 0;
  FSessionDir := ASessionDir;
  FStartTime := Now;
  FStartTick:=GetTickCount64;FResumeElapsed:=0;
end;

destructor TSensorLog.Destroy;
begin
  Close;
  inherited;
end;

procedure TSensorLog.OpenFile;
var
  Dir,Base: string;
  N:Integer;
begin
  if FOpened then Exit;

  FStartTime := Now;
  FStartTick:=GetTickCount64;FResumeElapsed:=0;FLastElapsed:=0;FClockElapsed:=0;
  FHasFrameData:=False;FSourceFlags:=0;FLastSourceFlags:=0;
  FHasLast:=False;FLastWasZero:=False;FLastWriteTime:=0;FTotalLines:=0;FLinesSinceFlush:=0;
  Dir := AppDirectory + FSessionDir;
  if ExtractFileDrive(FSessionDir)<>''then Dir:=FSessionDir;
  if GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'' then
    if GetEnvironmentVariable('REZVIVO_TEST_SESSION_DIR')<>'' then
      Dir:=GetEnvironmentVariable('REZVIVO_TEST_SESSION_DIR');

  if not DirectoryExists(Dir) then
  begin
    try
      ForceDirectories(Dir);
    except
      on E: Exception do
      begin
        Logger.Info('[SensorLog] ' + 'Cannot create dir: ' + E.Message);
        Exit;
      end;
    end;
  end;

  FFileName := Dir + PathDelim +
    'session_' + FormatDateTime('yyyy-mm-dd_hh-nn-ss', FStartTime) + '.csv';
  Base:=ChangeFileExt(FFileName,'');N:=0;
  while FileExists(FFileName)or FileExists(ChangeFileExt(FFileName,'.fit'))do begin
    Inc(N);FFileName:=Base+'-'+IntToStr(N)+'.csv';
  end;

  try
    FOpened := True;
    WriteHeader;
    Logger.Info('[SensorLog] ' + 'Started: ' + FFileName);
  except
    on E: Exception do
    begin FLocalError:=E.Message;FOpened:=False;Logger.Warning('[SensorLog] Cannot open file: '+E.Message);end;
  end;
end;

procedure TSensorLog.WriteHeader;
begin
  if not FOpened then Exit;
  FWriter:=TJournalWriter.Create(FFileName,
    'Timestamp' + CSVSep +
    'ElapsedSec' + CSVSep +
    'Power_W' + CSVSep +
    'AvgPower_W' + CSVSep +
    'Cadence_rpm' + CSVSep +
    'AvgCadence_rpm' + CSVSep +
    'Speed_kmh' + CSVSep +
    'HeartRate_bpm' + CSVSep +
    'Distance_m' + CSVSep +
    'Slope_pct' + CSVSep +
    'Calories' + CSVSep +
    'ResistanceLevel' + CSVSep +
    'ElapsedTime_s' + CSVSep +
    'IsMoving,TimerActive,Lap,TargetWatts,SourceFlags',False,FOwnerKey);
end;

function TSensorLog.GetError:String;
begin
  Result:=FLocalError;
  if(Result='')and(FWriter<>nil)then Result:=FWriter.ErrorText;
end;
function TSensorLog.GetElapsed:Double;
begin
  if FActivityClock then Result:=FClockElapsed
  else if FHasLast then Result:=FLastElapsed else Result:=FResumeElapsed;
end;

procedure TSensorLog.UseActivityClock;
begin
  if FActivityClock then Exit;
  FClockElapsed:=GetElapsed;FActivityClock:=True;
end;

procedure TSensorLog.Resume(const Journal:String;Elapsed:Double);
var Rows:TSensorSessionRecordArray;Last:TSensorSessionRecord;
begin
  Close;FFileName:=Journal;
  if IsNan(Elapsed)or IsInfinite(Elapsed)or(Elapsed<0)then Elapsed:=0;
  { The resume UI needs only the durable tail, not a second in-memory copy of
    the full multi-hour telemetry journal. A torn last line is not durable. }
  Rows:=ReadSession(Journal,True);
  FResumeElapsed:=Elapsed;FActivityClock:=True;FHasFrameData:=False;
  FSourceFlags:=ActivitySourceUnknown;
  if Length(Rows)>0 then begin
    Last:=Rows[High(Rows)];FResumeElapsed:=Max(Elapsed,Last.ElapsedSec);
    FSourceFlags:=Last.SourceFlags;
    FFrameData:=Default(TTrainerDataRecord);
    FFrameData.InstantPower:=Last.Power;FFrameData.InstantCadence:=Last.Cadence;
    FFrameData.HeartRate:=Last.HeartRate;FFrameData.InstantSpeed:=Last.SpeedKmh;
    FFrameData.Distance:=Last.DistanceM;FFrameSlope:=Last.SlopePct;FHasFrameData:=True;
    FLap:=Last.Lap;FTarget:=Last.TargetWatts;
  end;
  FStartTime:=UnixToDateTime(ParseStartTimeFromName(Journal),False);
  FClockElapsed:=FResumeElapsed;FStartTick:=GetTickCount64;
  FHasLast:=False;FLastWriteTick:=0;
  FWriter:=TJournalWriter.Create(Journal,'',True,FOwnerKey);FOpened:=True;
  { A checkpoint may be slightly newer than the last CSV row. Stop at the
    durable endpoint before crossing that gap; never extend stale power. }
  FTimerActive:=False;FRecordingEnabled:=True;
  if FHasFrameData then begin
    FClockElapsed:=Last.ElapsedSec;WriteData(FFrameData,FFrameSlope,True);
    FClockElapsed:=FResumeElapsed;
    if FClockElapsed>Last.ElapsedSec then WriteData(FFrameData,FFrameSlope,True);
  end;
end;

procedure TSensorLog.SetSessionState(TimerActive:Boolean;Lap,TargetWatts:Integer);
var Changed:Boolean;
begin
  Changed:=(FTimerActive<>TimerActive)or(FLap<>Lap)or(FTarget<>TargetWatts);
  FTimerActive:=TimerActive;FLap:=Lap;FTarget:=TargetWatts;
  if Changed and FOpened and not FRecordingResumePending then begin
    if FActivityClock and FHasFrameData then LogData(FFrameData,FFrameSlope)
    else if FHasLast then LogData(FLastData,FLastSlope);
  end;
end;

procedure TSensorLog.SetRecordingEnabled(Value:Boolean);
begin
  if FRecordingEnabled=Value then Exit;
  if not Value then SetSessionState(False,FLap,0);
  FRecordingEnabled:=Value;
  if Value then FRecordingResumePending:=True;
end;

procedure TSensorLog.SaveCheckpoint(const Path,Json:String);
begin
  if not FOpened then OpenFile;
  FlushFrame;
  if FWriter<>nil then FWriter.Snapshot(Path,Json);
end;

procedure TSensorLog.LogData(const Data: TTrainerDataRecord; ASlope: Single);
begin
  if not FActivityClock then begin
    if not FOpened then OpenFile;
    FSourceFlags:=FSourceFlags or ActivitySourceUnknown;
  end;
  WriteData(Data,ASlope,False);
end;

procedure TSensorLog.LogFrame(const Data:TTrainerDataRecord;ASlope:Single;Seconds:Double;SourceFlags:Byte);
var StartData:TTrainerDataRecord;WasActive:Boolean;
begin
  UseActivityClock;
  if not IsNan(Seconds)and not IsInfinite(Seconds)and(Seconds>0)and FRecordingEnabled then begin
    if not FOpened then OpenFile;
    if FOpened then begin
      if FRecordingResumePending then begin
        { Keyboard exploration never belongs to a training FIT. Publish a
          stopped odometer baseline before resuming the measured session,
          so its first frame cannot inherit distance travelled off-record. }
        StartData:=Data;
        if FHasFrameData then StartData.Distance:=FFrameData.Distance;
        WasActive:=FTimerActive;FTimerActive:=False;
        WriteData(StartData,ASlope,True);
        FTimerActive:=WasActive;
        FFrameData:=StartData;FFrameSlope:=ASlope;FHasFrameData:=True;
        FRecordingResumePending:=False;
      end;
      if FTimerActive then FSourceFlags:=FSourceFlags or SourceFlags;
      { Current accounting uses this frame's measured power over Seconds.
        Store it at the beginning, with the previous physical distance, then
        end with the new distance. FIT's preceding-sample integration now
        agrees with activity/daily even on power loss and pause boundaries. }
      StartData:=Data;
      if FHasFrameData then StartData.Distance:=FFrameData.Distance else StartData.Distance:=0;
      WriteData(StartData,ASlope,False);
      FClockElapsed:=FClockElapsed+Seconds;
      WriteData(Data,ASlope,False);
    end;
  end else if FRecordingEnabled then begin
    { Replayed/zero-duration motion establishes a baseline only. In
      particular it must not become FIT distance on the next active row. }
    SetSessionState(False,FLap,FTarget);
    WriteData(Data,ASlope,False);
  end;
  FFrameData:=Data;FFrameSlope:=ASlope;FHasFrameData:=True;
end;

procedure TSensorLog.FlushFrame;
begin
  if FOpened and FActivityClock and FHasFrameData and FRecordingEnabled then
    WriteData(FFrameData,FFrameSlope,FLastElapsed<FClockElapsed);
end;

procedure TSensorLog.WriteData(const Data:TTrainerDataRecord;ASlope:Single;Force:Boolean);
var
  ElapsedSec: Double;
  Moving: string;
  IsZero: Boolean;
  NowT: TDateTime;
  Changed: Boolean;
  SecondElapsed: Boolean;
  FS: TFormatSettings;
begin
  if not FRecordingEnabled then Exit;
  IsZero := (Data.InstantPower = 0) and (Data.InstantCadence = 0) and
            (Data.InstantSpeed < 0.1) and (Data.HeartRate = 0);

  { Don't open file until real data arrives }
  if not FOpened then
  begin
    if IsZero then Exit;
    OpenFile;
  end;
  if not FOpened then Exit;

  { Keep paused and zero-power samples: timer transitions must survive export. }
  FLastWasZero := IsZero;

  NowT := Now;

  { Thinning. Записываем строку только если:
      • это первая запись после открытия файла, ИЛИ
      • значимые сенсорные поля (Power/Cadence/Speed/HR/Distance)
        изменились по сравнению с предыдущей записью, ИЛИ
      • прошла как минимум секунда с предыдущей записи
        (для FIT нужна минимум 1 точка на секунду — иначе восстановить
        ход времени между событиями нельзя).
    Это срезает пустые повторы во много раз: на idle-стенде вместо 60
    Гц получаем 1 Гц; на активной езде — частота меняется с показаниями. }
  if FActivityClock then ElapsedSec:=FClockElapsed
  else ElapsedSec:=FResumeElapsed+(GetTickCount64-FStartTick)/1000.0;
  if FHasLast and not Force then
  begin
    Changed :=
      (Data.InstantPower    <> FLastPower)    or
      (Data.InstantCadence  <> FLastCadence)  or
      (Abs(Data.InstantSpeed - FLastSpeed) > 0.05) or
      (Data.HeartRate       <> FLastHR)       or
      (Data.Distance        <> FLastDistance) or
      (FTimerActive<>FLastTimerActive) or (FLap<>FLastLap) or(FTarget<>FLastTarget);
    if FActivityClock then SecondElapsed:=ElapsedSec-FLastElapsed>=1
    else SecondElapsed := GetTickCount64-FLastWriteTick>=1000;
    if (not Changed) and (not SecondElapsed) and(FSourceFlags=FLastSourceFlags)then Exit;
  end;

  if Data.IsMoving then Moving := '1' else Moving := '0';
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;

  try
    FWriter.Add(
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', NowT) + CSVSep +
      Format('%.6f', [ElapsedSec], FS) + CSVSep +
      IntToStr(Data.InstantPower) + CSVSep +
      IntToStr(Data.AveragePower) + CSVSep +
      IntToStr(Data.InstantCadence) + CSVSep +
      IntToStr(Data.AverageCadence) + CSVSep +
      Format('%.1f', [Data.InstantSpeed], FS) + CSVSep +
      IntToStr(Data.HeartRate) + CSVSep +
      IntToStr(Data.Distance) + CSVSep +
      Format('%.1f', [ASlope], FS) + CSVSep +
      IntToStr(Data.TotalEnergy) + CSVSep +
      FormatFloat('0.0', Data.ResistanceLevel, FS) + CSVSep +
      IntToStr(Data.ElapsedTime) + CSVSep +
      Moving+CSVSep+IntToStr(Ord(FTimerActive))+CSVSep+IntToStr(FLap)+CSVSep+IntToStr(FTarget)+CSVSep+IntToStr(FSourceFlags));
    FLocalError:='';

    Inc(FTotalLines);
    Inc(FLinesSinceFlush);

    FHasLast       := True;
    FLastPower     := Data.InstantPower;
    FLastCadence   := Data.InstantCadence;
    FLastSpeed     := Data.InstantSpeed;
    FLastHR        := Data.HeartRate;
    FLastDistance  := Data.Distance;
    FLastWriteTime := NowT;
    FLastElapsed:=ElapsedSec;
    FLastData:=Data;FLastSlope:=ASlope;
    FLastWriteTick:=GetTickCount64;FLastTimerActive:=FTimerActive;
    FLastLap:=FLap;FLastTarget:=FTarget;FLastSourceFlags:=FSourceFlags;
  except
    on E: Exception do
    begin
      if FLocalError<>E.Message then Logger.Warning('[SensorLog] Write error: '+E.Message);
      FLocalError:=E.Message;
    end;
  end;
end;

procedure TSensorLog.Flush;
begin
  { The worker commits every second, including when no new samples arrive.
    Close provides the synchronous final drain; UI callers never wait here. }
end;

procedure TSensorLog.Close(Completed:Boolean);
begin
  if not FOpened then Exit;
  try
    FlushFrame;
    if FWriter<>nil then begin
      FWriter.Finish(Completed);
      if FWriter.ErrorText<>''then begin
        FLocalError:=FWriter.ErrorText;Logger.Warning('[SensorLog] '+FLocalError);
      end;
      FreeAndNil(FWriter);
    end;
    Logger.Info('[SensorLog] ' + Format('Closed: %s (%d records)', [FFileName, FTotalLines]));
  except
    on E: Exception do
    begin
      FLocalError:=E.Message;
      Logger.Info('[SensorLog] ' + 'Close error: ' + E.Message);
    end;
  end;
  FOpened := False;
end;

{ ══════════════════════════════════════════════════════════════════
  Reverse-direction API: чтение CSV в массив записей.
  Используется FIT-writer'ом и очередью загрузки заездов.
  ══════════════════════════════════════════════════════════════════ }

class function TSensorLog.SessionDir: string;
begin
  Result := AppDirectory + 'sessions';
  if GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'' then
    if GetEnvironmentVariable('REZVIVO_TEST_SESSION_DIR')<>'' then
      Result:=GetEnvironmentVariable('REZVIVO_TEST_SESSION_DIR');
end;

class function TSensorLog.ParseStartTimeFromName(
  const AFileName: string): Int64;
var
  Base, TimePart: string;
  Y, Mo, D, H, Mi, S: Integer;
  DT: TDateTime;
begin
  { Имя по схеме session_YYYY-MM-DD_HH-MM-SS.csv (или с путём перед).
    Извлекаем именно эту часть; если формат не совпал — 0. }
  Result := 0;
  Base := ExtractFileName(AFileName);
  if Pos('session_', Base) <> 1 then Exit;
  if Length(Base) < Length('session_YYYY-MM-DD_HH-MM-SS') then Exit;

  { Y-M-D }
  if not TryStrToInt(Copy(Base, 9,  4), Y)  then Exit;
  if not TryStrToInt(Copy(Base, 14, 2), Mo) then Exit;
  if not TryStrToInt(Copy(Base, 17, 2), D)  then Exit;
  TimePart := Copy(Base, 20, 8);  { HH-MM-SS }
  if Length(TimePart) < 8 then Exit;
  if not TryStrToInt(Copy(TimePart, 1, 2), H)  then Exit;
  if not TryStrToInt(Copy(TimePart, 4, 2), Mi) then Exit;
  if not TryStrToInt(Copy(TimePart, 7, 2), S)  then Exit;

  try
    DT := EncodeDate(Y, Mo, D) + EncodeTime(H, Mi, S, 0);
  except
    Exit;
  end;

  { CSV пишет local time, переводим в UTC. }
  Result := DateTimeToUnix(LocalTimeToUniversal(DT));
end;

class function TSensorLog.CanUploadIntervals(const Rows:TSensorSessionRecordArray):Boolean;
var I:Integer;Flags:Byte;Measured:Boolean;
begin
  Flags:=0;Measured:=False;
  for I:=0 to High(Rows)do begin
    Flags:=Flags or Rows[I].SourceFlags;
    if(I<High(Rows))and Rows[I].TimerActive and(Rows[I].Power<>$FFFF)and
      (Rows[I+1].ElapsedSec>Rows[I].ElapsedSec)and
      ((Rows[I].SourceFlags and ActivitySourceSmartTrainer)<>0)then Measured:=True;
  end;
  Result:=Measured and((Flags and ActivitySourceSmartTrainer)<>0)and
    ((Flags and not(ActivitySourceSmartTrainer or ActivitySourceSensors))=0);
end;

class function TSensorLog.LoadSession(
  const AFileName: string): TSensorSessionRecordArray;
begin Result:=ReadSession(AFileName,False);end;

class function TSensorLog.ReadSession(const AFileName:string;TailOnly:Boolean):TSensorSessionRecordArray;
var
  StartUnix: Int64;
  Lines: TStringList;
  I, FieldCount, Capacity, OutCount: Integer;
  Line: string;
  Parts: array of string;
  Rec: TSensorSessionRecord;
  Elapsed:Double;
  Speed, Slope: Single;
  Power, Cadence, Distance: Integer;
  HR: Integer;
  FS: TFormatSettings;
  Input:TFileStream;
  TailOffset:Int64;
  TailByte:Byte;
  CompleteEnd:Boolean;

  procedure SplitCsv(const ALine: string);
  var
    P, Start, Cnt, Len, Idx: Integer;
  begin
    Cnt := 1;
    Len := Length(ALine);
    for P := 1 to Len do
      if ALine[P] = ',' then Inc(Cnt);
    SetLength(Parts, Cnt);
    Start := 1;
    Idx := 0;
    for P := 1 to Len do
      if ALine[P] = ',' then
      begin
        Parts[Idx] := Copy(ALine, Start, P - Start);
        Inc(Idx);
        Start := P + 1;
      end;
    if Idx < Cnt then
      Parts[Idx] := Copy(ALine, Start, Len - Start + 1);
  end;

  function PartFloat(AIdx: Integer; ADefault: Double): Double;
  begin
    if (AIdx < 0) or (AIdx >= Length(Parts)) then
    begin
      Result := ADefault;
      Exit;
    end;
    if not TryStrToFloat(Trim(Parts[AIdx]), Result, FS) then
      Result := ADefault;
  end;

  function PartInt(AIdx, ADefault: Integer): Integer;
  begin
    if (AIdx < 0) or (AIdx >= Length(Parts)) then
    begin
      Result := ADefault;
      Exit;
    end;
    if not TryStrToInt(Trim(Parts[AIdx]), Result) then
      Result := ADefault;
  end;

begin
  Result := nil;

  StartUnix := ParseStartTimeFromName(AFileName);
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  if StartUnix = 0 then
  begin
    Logger.Info('[SensorLog] ' + 'LoadSession: не удалось распознать время старта в имени: ' +
      AFileName);
    Exit;
  end;

  if not FileExists(AFileName) then Exit;

  Lines := TStringList.Create;
  try
    try
      Input:=TFileStream.Create(AFileName,fmOpenRead or fmShareDenyNone);
      try
        CompleteEnd:=True;
        if Input.Size>0 then begin
          Input.Position:=Input.Size-1;Input.ReadBuffer(TailByte,1);CompleteEnd:=TailByte=10;
          TailOffset:=0;
          if TailOnly then TailOffset:=Max(Int64(0),Input.Size-65536);
          Input.Position:=TailOffset;
        end;
        Lines.LoadFromStream(Input);
        { The writer always terminates committed rows with LF. Its append
          recovery discards an incomplete final row; readers must agree. }
        if not CompleteEnd and(Lines.Count>0)then Lines.Delete(Lines.Count-1);
      finally Input.Free end;
    except
      on E: Exception do
      begin
        Logger.Info('[SensorLog] ' + 'LoadSession read failed: ' + E.Message);
        Exit;
      end;
    end;

    if Lines.Count < 2 then Exit;     { только заголовок или пусто }

    { Колонки CSV (фиксированы в WriteHeader):
        0  Timestamp
        1  ElapsedSec
        2  Power_W
        3  AvgPower_W
        4  Cadence_rpm
        5  AvgCadence_rpm
        6  Speed_kmh
        7  HeartRate_bpm
        8  Distance_m
        9  Slope_pct
        10 Calories
        11 ResistanceLevel
        12 ElapsedTime_s
        13 IsMoving }
    FieldCount := 14;

    Capacity := Lines.Count - 1;
    SetLength(Result, Capacity);
    OutCount := 0;

    for I := 1 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if Line = '' then Continue;
      SplitCsv(Line);
      { Older locale-dependent writers could split decimal numbers into
        extra columns. Do not silently import these shifted records. }
      if (Length(Parts)<>FieldCount)and(Length(Parts)<>17)and(Length(Parts)<>18)then Continue;
      Rec:=Default(TSensorSessionRecord);

      Elapsed  := PartFloat(1, 0);
      Power    := PartInt(2, 0);
      Cadence  := PartInt(4, 0);
      Speed    := PartFloat(6, 0);
      HR       := PartInt(7, 0);
      Distance := PartInt(8, 0);
      Slope    := PartFloat(9, 0);
      if IsNan(Elapsed)or IsInfinite(Elapsed)or(Elapsed<0)then Continue;
      if(OutCount>0)and(Elapsed<Result[OutCount-1].ElapsedSec)then Continue;

      Rec.TimestampUtcUnix := StartUnix + Round(Elapsed);
      { Legacy hh:mm:ss rows remain readable, but have no unambiguous date
        after a crash/resume or midnight. Never infer that date from virtual
        elapsed time, which may advance faster/slower than wall time. }
      Rec.HasLocalTimestamp:=(Length(Parts[0])>=19)and(Pos('T',Parts[0])=11)and
        TryISOStrToDateTime(Parts[0],Rec.LocalTimestamp);
      Rec.ElapsedSec       := Elapsed;
      if Power < 0 then Power := 0;
      if Power > 65535 then Power := 65535;
      Rec.Power := Power;
      if Cadence < 0 then Cadence := 0;
      if Cadence > 65535 then Cadence := 65535;
      Rec.Cadence := Cadence;
      if HR < 0 then HR := 0;
      if HR > 255 then HR := 255;
      Rec.HeartRate := HR;
      Rec.SpeedKmh  := Speed;
      if Distance < 0 then Distance := 0;
      Rec.DistanceM := Distance;
      Rec.SlopePct  := Slope;
      Rec.HasSessionState:=Length(Parts)>=17;
      Rec.SourceFlags:=EnsureRange(PartInt(17,ActivitySourceUnknown),0,255);
      Rec.TimerActive:=not Rec.HasSessionState or(PartInt(14,0)<>0);
      Rec.Lap:=PartInt(15,0);Rec.TargetWatts:=EnsureRange(PartInt(16,0),0,65535);

      Result[OutCount] := Rec;
      Inc(OutCount);
    end;

    SetLength(Result, OutCount);
  finally
    Lines.Free;
  end;
end;

end.
