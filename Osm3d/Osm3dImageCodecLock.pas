unit Osm3dImageCodecLock;

{ Процессный замок на ВСЕ входы в кодек изображений
  (CGE LoadImage / SaveImage / LoadEncodedImage → Vampyre Imaging).

  Vampyre НЕ потокобезопасен: каждый Load*/Save* идёт через синглтоны —
  зарегистрированные TImageFileFormat (один TPNGFileFormat на процесс) и
  Imaging.GlobalMetadata, который КАЖДЫЙ вызов чистит и заполняет заново
  (TImageFileFormat.PrepareLoad → TMetadata.ClearMetaItems). Два потока,
  декодирующие одновременно, гоняются на этих структурах. Наблюдалось
  вживую оба лица одной гонки:

    1) EStringListError прямо в TMetadata.ClearMetaList (index out of
       bounds в TStringList.GetObject) — воркер нормал-канала fence-атласа
       чистил GlobalMetadata одновременно с соседним воркером;

    2) порча кучи FPC с детонацией ПОЗЖЕ в невинной аллокации —
       TFrameInfo.Create падал внутри SysGetMem при OSGetMem(40) во время
       параллельной сборки атласа зданий (3 TAtlasBuildWorker'а).

  Замок держится РОВНО вокруг декодирования/кодирования: вся дорогая
  обработка (resize, укладка каналов, гуттеры, свёртки) остаётся
  параллельной. Текущие пользователи: композитные атласы (build- и
  save-воркеры), грунтовый атлас, слиппи-тайлы (TSlippyFetchThread).

  ПРАВИЛО: любой новый код, зовущий LoadImage/SaveImage не с главного
  потока — или способный пересечься с такими потоками, — обязан брать
  этот же замок. }

{$mode objfpc}{$H+}

interface

procedure EnterImageCodec;
procedure LeaveImageCodec;

implementation

var
  Lock: TRTLCriticalSection;

procedure EnterImageCodec;
begin
  EnterCriticalSection(Lock);
end;

procedure LeaveImageCodec;
begin
  LeaveCriticalSection(Lock);
end;

initialization
  InitCriticalSection(Lock);

finalization
  DoneCriticalSection(Lock);

end.
