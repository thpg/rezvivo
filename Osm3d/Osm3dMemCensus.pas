unit Osm3dMemCensus;

{ Единая инвентаризация памяти ("census"). Каждая подсистема с заметным RAM/VRAM регистрирует ЗОНД
  (имя + вид + функция текущих байт) в конструкторе и снимает в деструкторе; MemCensusReport обходит
  живые зонды и печатает сводку в общий лог — расход всех кешей/рендеров в одном месте.

  Покрывает RAM: http mem-cache, heightmap-cache (Σ W*H*4), tile-index, trees-cpu; VRAM: grass
  (Σ*16Б), trees-gpu (Σ*stride). Резидентная геометрия тайлов здесь НЕ зондируется — её транзитную
  часть (TTileModel) покрывает Osm3dTileMemProfile.

  Закрыт под {$IFDEF TILE_MEM_PROFILE} (тот же дефайн, что у профайлера тайлов); без него юнит пуст. }

{$mode objfpc}{$H+}

interface

{$IFDEF TILE_MEM_PROFILE}
uses
  Osm3dStudioLog;          { TLogTarget }

type
  TMemKind = (mkRAM, mkVRAM);
  { Зонд: метод без аргументов, возвращает текущие байты подсистемы. }
  TMemBytesFunc = function: Int64 of object;

{ Регистрация/снятие. AOwner — объект-владелец (по нему снимаем). Потокобезопасно. }
procedure MemProbeAdd(AOwner: TObject; const AName: string;
  AKind: TMemKind; AFunc: TMemBytesFunc);
procedure MemProbeRemove(AOwner: TObject);

{ Печать сводки. Безопасно при ALog=nil (просто ничего не делает). }
procedure MemCensusReport(ALog: TLogTarget);

{ Печать не чаще, чем раз в AMinIntervalMs (удобно звать каждый кадр/тик). }
procedure MemCensusReportThrottled(ALog: TLogTarget; AMinIntervalMs: Int64 = 1000);
{$ENDIF}

implementation

{$IFDEF TILE_MEM_PROFILE}
uses
  SysUtils, Classes, dynlibs,
  CastleGL,         { glGetIntegerv — прямой запрос VRAM у драйвера }
  Osm3dGpuAccount,  { счётчики GL-ресурсов проекта }
  Osm3dMemBudget,   { ProcessRSSBytes — кросс-платформенный RSS процесса }
  Osm3dOSHeap;      { GetOSLargeBytes — крупные блоки в VirtualAlloc/mmap }

type
  TProbe = record
    Owner: TObject;
    Name:  string;
    Kind:  TMemKind;
    Func:  TMemBytesFunc;
  end;

var
  GLock:     TRTLCriticalSection;
  GProbes:   array of TProbe;
  GCount:    Integer = 0;
  GLastTick: Int64 = 0;

const
  MB = 1024.0 * 1024.0;

function FmtMB(B: Int64): string;
begin
  if B < 0 then Exit('  ERR');
  Result := FormatFloat('0.00', B / MB);
end;

{$IFDEF UNIX}
{ Пиковый RSS (VmHWM) из /proc — показывает «потолок» процесса даже когда
  текущий RSS уже осел ниже (классический high-water после всплеска генерации). }
function ProcStatusBytes(const AKey: string): Int64;
var
  sl: TStringList;
  i, p: Integer;
  s: string;
begin
  Result := 0;
  sl := TStringList.Create;
  try
    try sl.LoadFromFile('/proc/self/status'); except Exit; end;
    for i := 0 to sl.Count - 1 do
    begin
      s := sl[i];
      if Pos(AKey, s) = 1 then
      begin
        s := Trim(Copy(s, Length(AKey) + 1, MaxInt));
        p := 1;
        while (p <= Length(s)) and (s[p] in ['0'..'9']) do Inc(p);
        Result := StrToInt64Def(Copy(s, 1, p - 1), 0) * 1024;  { kB -> bytes }
        Exit;
      end;
    end;
  finally
    sl.Free;
  end;
end;
{$ENDIF}

{ Прямой запрос у драйвера: сколько VRAM реально занято — точка истины без
  гадания. NVIDIA/Mesa: GL_NVX_gpu_memory_info (total + current-free, kB).
  AMD: GL_ATI_meminfo (только free texture pool, kB). Зовётся в кадре, где
  GL-контекст текущий (CGE Update); при отсутствии расширения/контекста тихо
  возвращает False. AUsedBytes = -1 означает «известно только free» (ATI). }
function GpuVramQuery(out AUsedBytes, ATotalBytes: Int64): Boolean;
const
  GL_GPU_MEM_TOTAL_NVX = $9048;   { TOTAL_AVAILABLE_MEMORY_NVX }
  GL_GPU_MEM_AVAIL_NVX = $9049;   { CURRENT_AVAILABLE_VIDMEM_NVX }
  GL_TEX_FREE_ATI      = $87FC;   { TEXTURE_FREE_MEMORY_ATI }
var
  total, avail, atiFree: GLint;
begin
  Result := False; AUsedBytes := 0; ATotalBytes := 0;
  try
    while glGetError() <> GL_NO_ERROR do ;            { сбросить накопленные ошибки }
    total := 0; avail := 0;
    glGetIntegerv(GL_GPU_MEM_TOTAL_NVX, @total);
    glGetIntegerv(GL_GPU_MEM_AVAIL_NVX, @avail);
    if (glGetError() = GL_NO_ERROR) and (total > 0) then
    begin
      ATotalBytes := Int64(total) * 1024;
      AUsedBytes  := Int64(total - avail) * 1024;
      Exit(True);
    end;
    while glGetError() <> GL_NO_ERROR do ;
    atiFree := 0;
    glGetIntegerv(GL_TEX_FREE_ATI, @atiFree);        { kB свободной текстурной памяти }
    if (glGetError() = GL_NO_ERROR) and (atiFree > 0) then
    begin
      ATotalBytes := Int64(atiFree) * 1024;          { известно только free }
      AUsedBytes  := -1;
      Exit(True);
    end;
  except
    Result := False;
  end;
end;

procedure MemProbeAdd(AOwner: TObject; const AName: string;
  AKind: TMemKind; AFunc: TMemBytesFunc);
begin
  EnterCriticalSection(GLock);
  try
    if GCount >= Length(GProbes) then
      SetLength(GProbes, GCount + 8);
    GProbes[GCount].Owner := AOwner;
    GProbes[GCount].Name  := AName;
    GProbes[GCount].Kind  := AKind;
    GProbes[GCount].Func  := AFunc;
    Inc(GCount);
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure MemProbeRemove(AOwner: TObject);
var
  i: Integer;
begin
  EnterCriticalSection(GLock);
  try
    i := 0;
    while i < GCount do
      if GProbes[i].Owner = AOwner then
      begin
        GProbes[i] := GProbes[GCount - 1];   { swap-remove }
        Dec(GCount);
      end
      else
        Inc(i);
  finally
    LeaveCriticalSection(GLock);
  end;
end;

{$IFDEF MSWINDOWS}
{ Попроцессный VRAM через DXGI.
  IDXGIAdapter3.QueryVideoMemoryInfo(LOCAL).CurrentUsage отдаёт видеопамять
  ИМЕННО этого процесса (в отличие от NVX CURRENT_AVAILABLE_VIDMEM, который
  системный — вся VRAM всех процессов). Интерфейсы объявлены ровно до нужных
  методов; методы выше по vtable — заглушки для верных смещений, не зовутся.
  dxgi.dll грузится динамически: нет жёсткой зависимости компоновки. }
type
  TDXGIQueryVideoMemoryInfo = record
    Budget:                  UInt64;
    CurrentUsage:            UInt64;
    AvailableForReservation: UInt64;
    CurrentReservation:      UInt64;
  end;

  IDXGIObject = interface(IUnknown)
    ['{AEC22FB8-76F3-4639-9BE0-28EB43A67A2E}']
    function SetPrivateData(const Name: TGUID; DataSize: LongWord; pData: Pointer): HResult; stdcall;
    function SetPrivateDataInterface(const Name: TGUID; pUnknown: IUnknown): HResult; stdcall;
    function GetPrivateData(const Name: TGUID; var DataSize: LongWord; pData: Pointer): HResult; stdcall;
    function GetParent(const riid: TGUID; out ppParent: IUnknown): HResult; stdcall;
  end;

  IDXGIAdapter = interface(IDXGIObject)
    ['{2411E7E1-12AC-4CCF-BD14-9798E8534DC0}']
    function EnumOutputs(Output: LongWord; out ppOutput: IUnknown): HResult; stdcall;
    function GetDesc(pDesc: Pointer): HResult; stdcall;
    function CheckInterfaceSupport(const Name: TGUID; pUMDVersion: Pointer): HResult; stdcall;
  end;

  IDXGIAdapter1 = interface(IDXGIAdapter)
    ['{29038F61-3839-4626-91FD-086879011A05}']
    function GetDesc1(pDesc: Pointer): HResult; stdcall;
  end;

  IDXGIAdapter2 = interface(IDXGIAdapter1)
    ['{0AA1AE0A-FA0E-4B84-8644-E05FF8E5ACB5}']
    function GetDesc2(pDesc: Pointer): HResult; stdcall;
  end;

  IDXGIAdapter3 = interface(IDXGIAdapter2)
    ['{645967A4-1392-4310-A798-8053CE3E93FD}']
    function RegisterHardwareContentProtectionTeardownStatusEvent(hEvent: THandle; pdwCookie: Pointer): HResult; stdcall;
    function UnregisterHardwareContentProtectionTeardownStatus(dwCookie: LongWord): HResult; stdcall;
    function QueryVideoMemoryInfo(NodeIndex: LongWord; MemorySegmentGroup: LongWord;
      out pVideoMemoryInfo: TDXGIQueryVideoMemoryInfo): HResult; stdcall;
  end;

  IDXGIFactory = interface(IDXGIObject)
    ['{7B7166EC-21C7-44AE-B21A-C9AE321AE369}']
    function EnumAdapters(Adapter: LongWord; out ppAdapter: IDXGIAdapter): HResult; stdcall;
  end;

  TCreateDXGIFactory = function(const riid: TGUID; out ppFactory: IDXGIFactory): HResult; stdcall;

var
  gDxgiTried:    Boolean = False;
  gDxgiAdapter3: IDXGIAdapter3 = nil;

procedure DxgiInit;
const
  IID_IDXGIFactory: TGUID = '{7B7166EC-21C7-44AE-B21A-C9AE321AE369}';
var
  hDll:    TLibHandle;
  CreateF: TCreateDXGIFactory;
  Factory: IDXGIFactory;
  Adapter: IDXGIAdapter;
begin
  gDxgiTried := True;
  hDll := LoadLibrary('dxgi.dll');
  if hDll = NilHandle then Exit;
  Pointer(CreateF) := GetProcedureAddress(hDll, 'CreateDXGIFactory');
  if not Assigned(CreateF) then Exit;
  if CreateF(IID_IDXGIFactory, Factory) <> 0 then Exit;     { S_OK = 0 }
  if Factory = nil then Exit;
  if Factory.EnumAdapters(0, Adapter) <> 0 then Exit;       { адаптер 0 }
  if Adapter = nil then Exit;
  { QI к IDXGIAdapter3; nil если ОС/драйвер старые (до Windows 10 1803) }
  Supports(Adapter, IDXGIAdapter3, gDxgiAdapter3);
end;

{ True + AUsedBytes/ABudgetBytes — VRAM этого процесса (LOCAL-сегмент). }
function GpuVramQueryProcess(out AUsedBytes, ABudgetBytes: Int64): Boolean;
var info: TDXGIQueryVideoMemoryInfo;
begin
  Result := False; AUsedBytes := 0; ABudgetBytes := 0;
  if not gDxgiTried then DxgiInit;
  if gDxgiAdapter3 = nil then Exit;
  FillChar(info, SizeOf(info), 0);
  if gDxgiAdapter3.QueryVideoMemoryInfo(0, 0, info) <> 0 then Exit;  { 0 = LOCAL }
  AUsedBytes   := Int64(info.CurrentUsage);
  ABudgetBytes := Int64(info.Budget);
  Result := True;
end;
{$ENDIF}

procedure MemCensusReport(ALog: TLogTarget);
var
  i: Integer;
  b, ramTot, vramTot: Int64;
  kindS: string;
  rss, peak, held, nonHeap: Int64;
  gpuUsed, gpuTotal: Int64;
  gpuProcUsed, gpuProcBudget: Int64;
  hs: TFPCHeapStatus;
begin
  if ALog = nil then Exit;
  EnterCriticalSection(GLock);
  try
    ramTot := 0; vramTot := 0;
    ALog.Write(llInfo, Format('==== MEMORY CENSUS (%d probes) ====', [GCount]));
    for i := 0 to GCount - 1 do
    begin
      b := -1;
      if Assigned(GProbes[i].Func) then
        try
          b := GProbes[i].Func();
        except
          b := -1;
        end;
      if GProbes[i].Kind = mkRAM then kindS := 'RAM ' else kindS := 'VRAM';
      ALog.Write(llInfo, Format('  [%s] %-18s %s MB',
        [kindS, GProbes[i].Name, FmtMB(b)]));
      if b > 0 then
        if GProbes[i].Kind = mkRAM then ramTot := ramTot + b
                                   else vramTot := vramTot + b;
    end;
    ALog.Write(llInfo, Format(
      '  ---- probed RAM = %s MB | VRAM = %s MB (тайловая геометрия CGE/GPU — отдельно, см. [tile-mem]) ----',
      [FmtMB(ramTot), FmtMB(vramTot)]));

    { ---- процесс целиком: где сидит реальный RSS относительно зондов ----
      Зонды считают ЖИВЫЕ байты управляемых подсистем. Полный RSS почти всегда
      кратно больше, потому что в него входит то, что байтовые зонды не видят:
        (1) пик транзита генерации, удержанный менеджером кучи FPC после free
            (CurrHeapSize не отдаётся ОС -> high-water);
        (2) память GL-драйвера/VBO/framebuffers, отображённая в адресное
            пространство процесса (вне кучи FPC);
        (3) граф X3D в CGE на резидентные тайлы (тяжелее сырых массивов).
      GetFPCHeapStatus.CurrHeapSize = сколько менеджер забрал у ОС (входит в RSS).
      Если он 0 — включён внешний менеджер (cmem) и ориентир только RSS. }
    rss := ProcessRSSBytes;
    hs  := GetFPCHeapStatus;
    ALog.Write(llInfo, Format('  ---- PROCESS RSS = %s MB ----', [FmtMB(rss)]));
    if hs.CurrHeapSize > 0 then
    begin
      held    := Int64(hs.CurrHeapSize) - Int64(hs.CurrHeapUsed);
      nonHeap := rss - Int64(hs.CurrHeapSize);
      ALog.Write(llInfo, Format(
        '    FPC main-thread heap: used %s / reserved %s / peak-reserved %s MB',
        [FmtMB(Int64(hs.CurrHeapUsed)), FmtMB(Int64(hs.CurrHeapSize)),
         FmtMB(Int64(hs.MaxHeapSize))]));
      ALog.Write(llInfo, Format(
        '    main-thread reserved-used = %s MB | RSS minus main-thread heap = %s MB (includes CPU worker heaps, OSHeap, driver, code)',
        [FmtMB(held), FmtMB(nonHeap)]));
    end
    else
      ALog.Write(llInfo,
        '    FPC heap stats = 0 (внешний менеджер кучи, напр. cmem) — ориентир только RSS');

    { Крупные блоки идут мимо FPC-кучи в VirtualAlloc/mmap и
      возвращаются ОС при free. Это ЧАСТЬ non-heap; во время burst-генерации
      (много тайлов строится разом) тут виден транзиентный пик, спадающий
      после выгрузки. Остаток также включает кучи рабочих потоков;
      его нельзя интерпретировать как размер памяти драйвера. }
    ALog.Write(llInfo, Format(
      '    OSHeap крупные блоки (VirtualAlloc/mmap, возврат ОС): %s MB live, %d блоков',
      [FmtMB(Int64(GetOSLargeBytes)), Integer(GetOSLargeCount)]));

    { Точка истины по GPU: спрашиваем драйвер, сколько VRAM занято. }
    {$IFDEF MSWINDOWS}
    if GpuVramQueryProcess(gpuProcUsed, gpuProcBudget) then
      ALog.Write(llInfo, Format(
        '    GPU VRAM (процесс, DXGI): used %s MB / budget %s MB  | из них зонды видят VBO+grass = %s MB -> остальное = текстуры+FBO',
        [FmtMB(gpuProcUsed), FmtMB(gpuProcBudget), FmtMB(vramTot)]))
    else
    {$ENDIF}
    if GpuVramQuery(gpuUsed, gpuTotal) then
    begin
      if gpuUsed >= 0 then
        ALog.Write(llInfo, Format(
          '    GPU VRAM (NVX, СИСТЕМА — вся VRAM всех процессов ОС): used %s / total %s MB  | зонды этого процесса видят VBO+grass = %s MB (used здесь ОБЩИЙ по системе!)',
          [FmtMB(gpuUsed), FmtMB(gpuTotal), FmtMB(vramTot)]))
      else
        ALog.Write(llInfo, Format(
          '    GPU VRAM (драйвер, ATI): свободно текстурного пула %s MB (total/used драйвер не отдаёт)',
          [FmtMB(gpuTotal)]));
    end
    else
      ALog.Write(llInfo,
        '    GPU VRAM query: ни DXGI (Windows), ни NVX/ATI недоступны (нет GL-контекста либо неподдерживаемый GPU)');
    ALog.Write(llInfo, Format(
      '    GL-ресурсы (проект): tex %d live (created %d/deleted %d) | buf %d live (%d/%d) | vao %d live (%d/%d)',
      [Integer(GpuTexLive), Integer(GpuTexCreated), Integer(GpuTexDeleted),
       Integer(GpuBufLive), Integer(GpuBufCreated), Integer(GpuBufDeleted),
       Integer(GpuVaoLive), Integer(GpuVaoCreated), Integer(GpuVaoDeleted)]));
    ALog.Write(llInfo, Format(
      '    distance-field (cumulative, per-block churn): %d полей, %s MB загружено (grayscale)',
      [Integer(GpuDistFieldCount), FmtMB(GpuDistFieldBytes)]));
    {$IFDEF UNIX}
    peak := ProcStatusBytes('VmHWM:');
    if peak > 0 then
      ALog.Write(llInfo, Format('    RSS peak (VmHWM) = %s MB', [FmtMB(peak)]));
    {$ENDIF}
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure MemCensusReportThrottled(ALog: TLogTarget; AMinIntervalMs: Int64);
var
  now: Int64;
begin
  now := GetTickCount64;
  if (GLastTick <> 0) and (now - GLastTick < AMinIntervalMs) then Exit;
  GLastTick := now;
  MemCensusReport(ALog);
end;
{$ENDIF}

initialization
  {$IFDEF TILE_MEM_PROFILE}
  InitCriticalSection(GLock);
  {$ENDIF}

finalization
  {$IFDEF TILE_MEM_PROFILE}
  DoneCriticalSection(GLock);
  {$ENDIF}

end.
