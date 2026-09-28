{ FreezeDiagLog — независимый диагностический лог.

  Зачем отдельный модуль:
    Стандартный Logger.Info буферизуется (что мы увидели в trainer_*.log:
    burst'ы по 100 строк с одним внешним timestamp). При краше процесса
    содержимое буфера теряется, и реальную точку смерти не видно.

  Что делает этот модуль:
    Пишет каждое сообщение прямо в файл, потом вызывает FlushFileBuffers
    (Windows) / fsync (POSIX) — содержимое попадает на диск даже если
    процесс упадёт через 100 мкс. Thread-safe через CriticalSection. По
    скорости заметно медленнее обычного Logger — поэтому используется
    ТОЛЬКО на критических точках (heart-beat, вход/выход тяжёлых
    методов, обработчик исключения). Не для общего логирования.

  Watchdog:
    FreezeDiagStartWatchdog поднимает поток, который пишет строку
    "[watchdog] tick=N main_beat_age=X ms loc=..." раз в AIntervalMs.
    Main thread обязан периодически звать FreezeDiagMainBeat; растущий
    main_beat_age при живых тиках = main thread завис (а процесс жив).
    FreezeDiagSetLocation обновляет "хлебную крошку" loc — последнее
    место, которое main thread пометил как достигнутое.

  Имя файла: рядом с trainer_*.log, с префиксом freeze_direct_. Перезапись
  при каждом старте.

  Восстановлено 2026-07-24 по бэкапу FreezeDiagLog_20260528_073331.pas +
  наблюдаемому поведению watchdog в архивных freeze_direct_*.log (исходник
  версии с watchdog был утерян, в castle-engine-output остался только .ppu). }
unit FreezeDiagLog;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

{ Инициализировать. ASessionDir — папка где лежат trainer_*.log; туда же
  пойдёт freeze_direct_*.log. Безопасно звать повторно (no-op). }
procedure FreezeDiagInit(const ASessionDir: string);

{ Записать строку. Префикс с timestamp + thread id добавляется
  автоматически. Делает Flush на диск в каждом вызове. Можно звать из
  любого потока. Если модуль не инициализирован — no-op. }
procedure FreezeDiagWrite(const ALine: string);
procedure FreezeDiagWriteFmt(const AFmt: string; const AArgs: array of const);

{ Запустить watchdog-поток с периодом AIntervalMs миллисекунд.
  Повторный вызов — no-op. }
procedure FreezeDiagStartWatchdog(AIntervalMs: Cardinal);

{ Отметка "main thread жив" — watchdog показывает её возраст. }
procedure FreezeDiagMainBeat;

{ Отметка местоположения main thread ("хлебная крошка"). }
procedure FreezeDiagSetLocation(const ALoc: string);

{ Остановить watchdog и закрыть файл — обычно не нужно, при выходе
  процесса вызывается из finalization; но если хост хочет явно закрыть
  лог, метод доступен. }
procedure FreezeDiagShutdown;

implementation

uses
  CastleLog;

var
  GCS:          TRTLCriticalSection;
  GInited:      Boolean = False;
  GCSInit:      Boolean = False;
  GLoc:         string = '?';
  GMainBeat:    QWord = 0;
  GMainBeatSet: Boolean = False;
  GWatchdog:    TThread = nil;

type
  TFreezeWatchdog = class(TThread)
  private
    FInterval: Cardinal;
  protected
    procedure Execute; override;
  public
    constructor Create(AInterval: Cardinal);
  end;

procedure EnsureCS;
begin
  if not GCSInit then
  begin
    InitCriticalSection(GCS);
    GCSInit := True;
  end;
end;

procedure FreezeDiagInit(const ASessionDir: string);
begin
  if GInited then Exit;
  EnsureCS;
  GInited := True;
  FreezeDiagWrite('=== FreezeDiagLog opened (CastleLog) ===');
  if ASessionDir = '' then ;
end;

procedure FreezeDiagWrite(const ALine: string);
begin
  try
    WritelnLog('Freeze', ALine);
  except
  end;
end;

procedure FreezeDiagWriteFmt(const AFmt: string; const AArgs: array of const);
begin
  if not GInited then Exit;
  try
    FreezeDiagWrite(Format(AFmt, AArgs));
  except
    { Format может бросить EConvertError если AFmt/AArgs не сходятся —
      проглатываем. }
  end;
end;

procedure FreezeDiagMainBeat;
begin
  if not GCSInit then Exit;
  EnterCriticalSection(GCS);
  try
    GMainBeat := GetTickCount64;
    GMainBeatSet := True;
  finally
    LeaveCriticalSection(GCS);
  end;
end;

procedure FreezeDiagSetLocation(const ALoc: string);
begin
  if not GCSInit then Exit;
  EnterCriticalSection(GCS);
  try
    GLoc := ALoc;
  finally
    LeaveCriticalSection(GCS);
  end;
end;

constructor TFreezeWatchdog.Create(AInterval: Cardinal);
begin
  { Создаём suspended: поток стартует (Start) только ПОСЛЕ присваивания
    полей — иначе Execute мог прочитать ещё нулевой FInterval и
    превратить сон ниже в busy-loop. }
  inherited Create(True);
  FInterval := AInterval;
  FreeOnTerminate := False;
  Start;
end;

procedure TFreezeWatchdog.Execute;
var
  Tick: Integer;
  Age:  QWord;
  Loc:  string;
  BeatSet: Boolean;
  Line: string;
  Waited: Cardinal;
begin
  Tick := 0;
  while not Terminated do
  begin
    Inc(Tick);
    EnterCriticalSection(GCS);
    try
      BeatSet := GMainBeatSet;
      Age     := GetTickCount64 - GMainBeat;
      Loc     := GLoc;
    finally
      LeaveCriticalSection(GCS);
    end;
    { В общий лог пишем тик только если main thread завис — иначе
      watchdog забивает файл 5 раз в секунду. }
    if (not BeatSet) or (Age >= 1500) then
    begin
      if BeatSet then
        Line := Format('[watchdog] tick=%d main_beat_age=%d ms loc=%s',
          [Tick, Age, Loc])
      else
        Line := Format('[watchdog] tick=%d main_beat=never loc=%s', [Tick, Loc]);
      FreezeDiagWrite(Line);
    end;
    { Спим порциями, чтобы Terminate отрабатывал быстро на шатдауне. }
    Waited := 0;
    while (not Terminated) and (Waited < FInterval) do
    begin
      Sleep(20);
      Inc(Waited, 20);
    end;
  end;
  FreezeDiagWrite('Watchdog thread stopped');
end;

procedure FreezeDiagStartWatchdog(AIntervalMs: Cardinal);
begin
  if GWatchdog <> nil then Exit;
  EnsureCS;
  GWatchdog := TFreezeWatchdog.Create(AIntervalMs);
end;

procedure FreezeDiagShutdown;
begin
  if GWatchdog <> nil then
  begin
    GWatchdog.Terminate;
    GWatchdog.WaitFor;
    FreeAndNil(GWatchdog);
  end;
  GInited := False;
  FreezeDiagWrite('=== FreezeDiagLog closed ===');
end;

initialization

finalization
  FreezeDiagShutdown;
  if GCSInit then
  begin
    DoneCriticalSection(GCS);
    GCSInit := False;
  end;

end.
