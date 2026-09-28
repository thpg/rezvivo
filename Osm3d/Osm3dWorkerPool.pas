unit Osm3dWorkerPool;
{ Общий пул CPU-воркеров для параллельных фан-аутов генерации (карв-полосы,
  weld-полосы, drape/level/smooth). Единая политика допуска потоков на весь
  процесс: НЕ переподписывать CPU, когда несколько блоков генерируются разом.

  Политика допуска ещё одного воркера (OR двух условий):
    1) собственных активных воркеров < POOL_MIN_WORKERS (0 или 1), ЛИБО
    2) системная загрузка CPU < POOL_CPU_TARGET (80%).
  => всегда грузим CPU минимум двумя своими задачами (даже если машина занята
     чужой работой), а сверх того добираем сами лишь пока общая загрузка < 80%
     (20% оставляем другим процессам).

  Ключевое свойство безопасности: ParallelForPool — CALLER-DRAINING. Работа
  разбита на чанки в общей атомарной очереди; ВЫЗЫВАЮЩИЙ поток сам разбирает
  чанки наравне с воркерами. Поэтому вся работа завершается даже при НУЛЕ
  допущенных воркеров — недопуск воркера НИКОГДА не теряет работу и не может
  вызвать дедлок. Динамический разбор заодно балансирует нагрузку. }

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes;

type
  { диапазонная задача: обработать полуинтервал [AStartIdx, AEndExcl) }
  TPoolRangeProc = procedure(Ctx: Pointer; AStartIdx, AEndExcl: Integer);

const
  POOL_CPU_TARGET  = 0.80;   { добираем CPU сами лишь пока общая загрузка < 80% }
  POOL_MIN_WORKERS = 2;      { но всегда держим >= 2 своих воркера на CPU }

{ Параллельный for с допуском по политике выше. Разбивает [0,Count) на чанки;
  вызывающий поток участвует в разборе -> завершение гарантировано при любом
  числе допущенных воркеров. AMinPerThread ограничивает МАКС. число потоков
  (не дробить мелкую работу), как в прежней реализации. }
procedure ParallelForPool(Count: Integer; AProc: TPoolRangeProc;
  ACtx: Pointer; AMinPerThread: Integer = 8192);

{ Примитивы допуска для собственных пулов (напр. карв-полосы), которым нужен
  свой цикл разбора, а не диапазонный for. Контракт: на КАЖДЫЙ успешный
  PoolTryAdmitWorker ровно один PoolReleaseWorker после WaitFor воркера.
  Вызывающий поток ОБЯЗАН сам выполнить недопущенные единицы работы. }
function  PoolTryAdmitWorker: Boolean;
procedure PoolReleaseWorker;

{ Текущее число активных допущенных воркеров (диагностика). }
function ActivePoolWorkers: Integer;

{ Кэш системной загрузки CPU [0..1]; -1 если недоступно. }
function SystemCpuBusyFraction: Double;

{ Тест/тюнинг: принудительно задать загрузку CPU (0..1); значение < 0 снимает
  подмену и возвращает реальный замер. В проде не используется. }
procedure PoolSetCpuOverride(AValue: Double);

{ Тест/тюнинг: принудительно задать верхний предел числа потоков на фан-аут
  (> 0). Значение <= 0 снимает подмену (используется TThread.ProcessorCount).
  В проде не используется; нужен, чтобы прогонять многопоточный путь на
  машинах/контейнерах с одним видимым CPU. }
procedure PoolSetMaxThreadsOverride(AValue: Integer);

implementation

uses
  {$IFDEF UNIX}BaseUnix{$ENDIF}
  {$IFDEF WINDOWS}Windows{$ENDIF};

{$IFDEF WINDOWS}
{ GetSystemTimes есть в kernel32 (Windows XP+), но не объявлен в модуле Windows
  у FPC 3.2.2 — импортируем сами под приватным именем, без конфликта с модулем. }
function WP_GetSystemTimes(lpIdleTime, lpKernelTime, lpUserTime: PFileTime): BOOL;
  stdcall; external 'kernel32' name 'GetSystemTimes';
{$ENDIF}

{ ─────────────────────────── замер загрузки CPU ─────────────────────────── }
var
  gCpuLock:      TRTLCriticalSection;
  gCpuHave:      Boolean = False;   { есть предыдущий сэмпл счётчиков }
  gCpuLastTick:  QWord   = 0;
  gCpuPrevBusy:  QWord   = 0;
  gCpuPrevTotal: QWord   = 0;
  gCpuFrac:      Double  = -1;      { последняя вычисленная доля; -1 = нет данных }
  gCpuOverride:  Double  = -1;      { < 0 = нет подмены }
  gMaxThrOverride: Integer = 0;     { > 0 = подмена ProcessorCount (тест/тюнинг) }

{ Прочитать сырые счётчики busy/total. Возвращает False, если недоступно. }
function ReadCpuCounters(out ABusy, ATotal: QWord): Boolean;
{$IFDEF UNIX}
var
  fh, n, i, p: Integer;
  buf: array[0..1023] of Char;
  s: string;
  vals: array of QWord;
  tok: string;
  idle: QWord;
begin
  Result := False; ABusy := 0; ATotal := 0;
  fh := FpOpen('/proc/stat', O_RDONLY);
  if fh < 0 then Exit;
  n := FpRead(fh, buf[0], SizeOf(buf) - 1);
  FpClose(fh);
  if n <= 0 then Exit;
  SetString(s, PChar(@buf[0]), n);
  { первая строка: "cpu  u n s idle iowait irq softirq steal ..." }
  p := Pos(#10, s);
  if p > 0 then s := Copy(s, 1, p - 1);
  { отрезать метку "cpu" }
  p := Pos(' ', s);
  if p <= 0 then Exit;
  s := Trim(Copy(s, p + 1, Length(s)));
  { токенизировать поля }
  vals := nil;
  while s <> '' do
  begin
    p := Pos(' ', s);
    if p <= 0 then begin tok := s; s := ''; end
    else begin tok := Copy(s, 1, p - 1); s := Trim(Copy(s, p + 1, Length(s))); end;
    if tok <> '' then
    begin
      SetLength(vals, Length(vals) + 1);
      vals[High(vals)] := StrToQWordDef(tok, 0);
    end;
  end;
  if Length(vals) < 5 then Exit;
  ATotal := 0;
  for i := 0 to High(vals) do ATotal := ATotal + vals[i];
  idle := vals[3];                          { idle }
  if Length(vals) >= 5 then idle := idle + vals[4];  { + iowait }
  if ATotal < idle then Exit;
  ABusy := ATotal - idle;
  Result := True;
end;
{$ELSE}
{$IFDEF WINDOWS}
var
  ftIdle, ftKern, ftUser: TFileTime;
  qi, qk, qu: QWord;
begin
  Result := False; ABusy := 0; ATotal := 0;
  if not WP_GetSystemTimes(@ftIdle, @ftKern, @ftUser) then Exit;
  qi := (QWord(ftIdle.dwHighDateTime) shl 32) or QWord(ftIdle.dwLowDateTime);
  qk := (QWord(ftKern.dwHighDateTime) shl 32) or QWord(ftKern.dwLowDateTime);
  qu := (QWord(ftUser.dwHighDateTime) shl 32) or QWord(ftUser.dwLowDateTime);
  ATotal := qk + qu;         { kernel time ВКЛЮЧАЕТ idle }
  if ATotal < qi then Exit;
  ABusy := ATotal - qi;
  Result := True;
end;
{$ELSE}
begin
  Result := False; ABusy := 0; ATotal := 0;   { прочие ОС: замер недоступен }
end;
{$ENDIF}
{$ENDIF}

function SystemCpuBusyFraction: Double;
var
  nowT, b, t, db, dt: QWord;
begin
  if gCpuOverride >= 0 then begin Result := gCpuOverride; Exit; end;
  EnterCriticalSection(gCpuLock);
  try
    nowT := GetTickCount64;
    if gCpuHave and (nowT - gCpuLastTick < 200) then
    begin
      Result := gCpuFrac;         { свежий кэш в пределах окна 200мс }
      Exit;
    end;
    if not ReadCpuCounters(b, t) then
    begin
      Result := gCpuFrac;         { держим последнее известное (возможно -1) }
      Exit;
    end;
    if gCpuHave and (t > gCpuPrevTotal) then
    begin
      db := b - gCpuPrevBusy;
      dt := t - gCpuPrevTotal;
      if dt > 0 then gCpuFrac := db / dt;
    end;
    gCpuPrevBusy  := b;
    gCpuPrevTotal := t;
    gCpuLastTick  := nowT;
    gCpuHave      := True;
    Result := gCpuFrac;
  finally
    LeaveCriticalSection(gCpuLock);
  end;
end;

procedure PoolSetCpuOverride(AValue: Double);
begin
  if AValue > 1 then AValue := 1;
  gCpuOverride := AValue;   { < 0 -> снять подмену }
end;

procedure PoolSetMaxThreadsOverride(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  gMaxThrOverride := AValue;   { 0 -> снять подмену }
end;

{ ──────────────────────────── допуск воркеров ───────────────────────────── }
var
  gAdmitLock: TRTLCriticalSection;
  gActive:    Integer = 0;   { живые допущенные воркеры; только под gAdmitLock }

function ActivePoolWorkers: Integer;
begin
  EnterCriticalSection(gAdmitLock);
  Result := gActive;
  LeaveCriticalSection(gAdmitLock);
end;

function PoolTryAdmitWorker: Boolean;
var
  frac: Double;
begin
  { доля CPU берётся ДО gAdmitLock (свой замок) — без вложенной блокировки }
  frac := SystemCpuBusyFraction;
  EnterCriticalSection(gAdmitLock);
  try
    if (gActive < POOL_MIN_WORKERS)         { пол: всегда >= 2 своих }
       or (frac < 0)                        { замер недоступен -> не мешаем }
       or (frac < POOL_CPU_TARGET) then     { есть запас до 80% -> добираем }
    begin
      Inc(gActive);
      Result := True;
    end
    else
      Result := False;
  finally
    LeaveCriticalSection(gAdmitLock);
  end;
end;

procedure PoolReleaseWorker;
begin
  EnterCriticalSection(gAdmitLock);
  if gActive > 0 then Dec(gActive);
  LeaveCriticalSection(gAdmitLock);
end;

{ ─────────────────── caller-draining параллельный for ────────────────────── }
type
  PPoolShared = ^TPoolShared;
  TPoolShared = record
    Proc:  TPoolRangeProc;
    Ctx:   Pointer;
    Count: Integer;
    Chunk: Integer;
    Next:  Integer;      { атомарный курсор следующего чанка }
  end;

  TPoolHelper = class(TThread)
  private
    FSh: PPoolShared;
  protected
    procedure Execute; override;
  public
    constructor Create(ASh: PPoolShared);
  end;

procedure DrainQueue(Sh: PPoolShared);
var s, e: Integer;
begin
  repeat
    { атомарно забрать свой чанк: InterlockedExchangeAdd возвращает старый Next }
    s := InterlockedExchangeAdd(Sh^.Next, Sh^.Chunk);
    if s >= Sh^.Count then Break;
    e := s + Sh^.Chunk;
    if e > Sh^.Count then e := Sh^.Count;
    Sh^.Proc(Sh^.Ctx, s, e);
  until False;
end;

constructor TPoolHelper.Create(ASh: PPoolShared);
begin
  FSh := ASh;
  inherited Create(False);
end;

procedure TPoolHelper.Execute;
begin
  Priority := tpLowest;   { уступать основному render/UI потоку }
  DrainQueue(FSh);
end;

procedure ParallelForPool(Count: Integer; AProc: TPoolRangeProc;
  ACtx: Pointer; AMinPerThread: Integer = 8192);
var
  Sh: TPoolShared;
  MaxThreads, nChunks, wantHelpers, t, made: Integer;
  Helpers: array of TPoolHelper;
begin
  if (Count <= 0) or (AProc = nil) then Exit;

  MaxThreads := TThread.ProcessorCount;
  if gMaxThrOverride > 0 then MaxThreads := gMaxThrOverride;   { тест/тюнинг }
  if MaxThreads < 1  then MaxThreads := 1;
  if MaxThreads > 32 then MaxThreads := 32;
  if AMinPerThread < 1 then AMinPerThread := 1;
  if MaxThreads > (Count div AMinPerThread) + 1 then
    MaxThreads := (Count div AMinPerThread) + 1;

  Sh.Proc  := AProc;
  Sh.Ctx   := ACtx;
  Sh.Count := Count;
  { ~2 чанка на потенциальный поток: динамический разбор балансирует нагрузку
    (неравномерные полосы) без заметной атомарной конкуренции }
  Sh.Chunk := (Count + (MaxThreads * 2) - 1) div (MaxThreads * 2);
  if Sh.Chunk < 1 then Sh.Chunk := 1;
  Sh.Next  := 0;

  if MaxThreads <= 1 then
  begin
    DrainQueue(@Sh);   { мелкая работа — целиком на вызывающем }
    Exit;
  end;

  { сколько всего чанков — не плодить воркеров больше, чем есть работы }
  nChunks := (Count + Sh.Chunk - 1) div Sh.Chunk;
  wantHelpers := MaxThreads - 1;              { вызывающий — ещё один участник }
  if wantHelpers > nChunks - 1 then wantHelpers := nChunks - 1;
  if wantHelpers < 0 then wantHelpers := 0;

  { допуск воркеров по политике; недопущенные -> разберёт вызывающий/допущенные }
  made := 0;
  try
    try
      if wantHelpers > 0 then
      begin
        SetLength(Helpers, wantHelpers);
        for t := 0 to wantHelpers - 1 do
        begin
          if not PoolTryAdmitWorker then Break;
          try
            Helpers[made] := TPoolHelper.Create(@Sh);
            Inc(made);
          except
            PoolReleaseWorker;
            raise;
          end;
        end;
      end;

      { The caller also drains work. Its exception must not outlive Sh/Ctx. }
      DrainQueue(@Sh);
    finally
      { Join every created helper before releasing the shared stack record,
        including failure in the caller or construction of a later helper. }
      for t := 0 to made - 1 do Helpers[t].WaitFor;
    end;

    { TThread owns FatalException and frees it in its destructor. Copy its
      diagnostic after all joins, while preserving caller exceptions above. }
    for t := 0 to made - 1 do
      if Helpers[t].FatalException <> nil then
      begin
        if Helpers[t].FatalException is Exception then
          raise Exception.CreateFmt('Pool helper %s: %s',
            [Helpers[t].FatalException.ClassName,
             Exception(Helpers[t].FatalException).Message]);
        raise Exception.CreateFmt('Pool helper failed: %s',
          [Helpers[t].FatalException.ClassName]);
      end;
  finally
    for t := 0 to made - 1 do
    begin
      try
        Helpers[t].Free;
      finally
        PoolReleaseWorker;
      end;
    end;
  end;
end;

initialization
  InitCriticalSection(gCpuLock);
  InitCriticalSection(gAdmitLock);
  { первичный сэмпл счётчиков — чтобы первый же ParallelForPool получил дельту }
  SystemCpuBusyFraction;

finalization
  DoneCriticalSection(gAdmitLock);
  DoneCriticalSection(gCpuLock);

end.
