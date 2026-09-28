unit Osm3dOSHeap;

{ OS-direct large-block allocator (transparent memory-manager overlay).

  Problem: FPC's default heap keeps freed memory in free-lists and does NOT return it to the OS
  (especially on Windows), so the huge transient build buffers (terrain ~2.35M verts, water, indices,
  composite mesh) leave RSS plateaued at multi-GB across worker threads even after free.

  This installs a memory-manager wrapper: allocations >= LARGE_THRESHOLD come straight from the OS
  (VirtualAlloc / mmap) and are released to it on free (VirtualFree MEM_RELEASE / munmap), so RSS
  drops immediately; smaller allocations pass through to the original fast manager unchanged. Fully
  transparent — any dynamic array / class / string whose block crosses the threshold lands in OS
  memory and is reclaimed on free.

  Enable by adding this unit to the program uses clause as EARLY as possible (its initialization
  installs the wrapper before heavy allocation); InstallOSLargeBlockManager is also exported.

  Notes: per-block overhead is one 16-byte header (negligible vs a large block). GetFPCHeapStatus
  reports only the underlying manager — OS blocks show as RSS that rises on alloc and FALLS on free;
  GetOSLargeBytes/Count expose the live OS-allocated total for probes. }

{$mode objfpc}{$H+}

interface

{ Install the wrapper over the current memory manager. Idempotent and safe to
  call once at startup (single-threaded). Auto-called from initialization. }
procedure InstallOSLargeBlockManager;

{ Live bytes / block count currently held directly from the OS (for census). }
function GetOSLargeBytes: PtrUInt;
function GetOSLargeCount: PtrUInt;
{ Allocation threshold actually in effect (bytes). }
function GetOSLargeThreshold: PtrUInt;

implementation

uses
  {$IFDEF WINDOWS}Windows{$ELSE}BaseUnix{$ENDIF};

const
  { Allocations of at least this size are taken from the OS. 32 KiB catches
    not only the giant mesh buffers (vertex/index/normal/uv arrays -- tens of
    MB each) but also the medium transient buffers (image rows, stream
    capacity doublings), while leaving the millions of small allocations on
    the fast free-list manager. Tunable. }
  LARGE_THRESHOLD = PtrUInt(1) * 1024 * 32;

  { Page granularity used only for a fast "is this one of ours" pre-check. Our
    data pointer always sits at (OS-page-aligned base) + HDR_SIZE, so its low
    bits are exactly HDR_SIZE. 4096 is the common page size on Win/Linux x86-64
    (VirtualAlloc returns 64 KiB-aligned, also a multiple of 4096). }
  PAGE_MASK = PtrUInt(4096) - 1;

  HDR_MAGIC = QWord($05A11AB1ED1A6E07);   { distinctive 64-bit marker }

type
  PLargeHdr = ^TLargeHdr;
  TLargeHdr = record
    Magic: QWord;        { HDR_MAGIC if this block is OS-allocated by us }
    Size:  PtrUInt;      { usable size requested by the caller (excl. header) }
  end;                   { sizeof = 16 on 64-bit -> keeps returned ptr 16-aligned }

var
  OldMM:        TMemoryManager;     { the manager we wrap (default / cmem) }
  Installed:    Boolean = False;
  gLiveBytes:   Int64 = 0;          { sum of usable sizes of live OS blocks }
  gLiveCount:   Int64 = 0;

{ ---- raw OS map / unmap ---------------------------------------------------- }

function OSMap(TotalBytes: PtrUInt): Pointer; inline;
begin
  {$IFDEF WINDOWS}
  Result := VirtualAlloc(nil, TotalBytes, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  {$ELSE}
  Result := fpmmap(nil, TotalBytes, PROT_READ or PROT_WRITE,
                   MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  if Result = Pointer(-1) then Result := nil;   { MAP_FAILED }
  {$ENDIF}
end;

procedure OSUnmap(Base: Pointer; TotalBytes: PtrUInt); inline;
begin
  {$IFDEF WINDOWS}
  VirtualFree(Base, 0, MEM_RELEASE);            { size must be 0 for MEM_RELEASE }
  {$ELSE}
  fpmunmap(Base, TotalBytes);
  {$ENDIF}
end;

{ Allocate Size usable bytes straight from the OS, with our header in front. }
function OSAllocLarge(Size: PtrUInt): Pointer;
var base: Pointer;
begin
  base := OSMap(Size + SizeOf(TLargeHdr));
  if base = nil then begin Result := nil; Exit; end;
  PLargeHdr(base)^.Magic := HDR_MAGIC;
  PLargeHdr(base)^.Size  := Size;
  InterLockedExchangeAdd64(gLiveBytes, Int64(Size));
  InterLockedIncrement64(gLiveCount);
  Result := Pointer(PtrUInt(base) + SizeOf(TLargeHdr));
end;

{ Is p one of our OS blocks? Fast page-offset pre-check, then the magic. The
  magic read is always inside mapped memory (our header, or -- for the rare
  default block whose data happens to sit at page+HDR_SIZE -- inside the
  underlying heap page), so it never faults. }
function OursHdr(p: Pointer): PLargeHdr; inline;
var h: PLargeHdr;
begin
  Result := nil;
  if p = nil then Exit;
  if (PtrUInt(p) and PAGE_MASK) <> SizeOf(TLargeHdr) then Exit;
  h := PLargeHdr(PtrUInt(p) - SizeOf(TLargeHdr));
  if h^.Magic = HDR_MAGIC then Result := h;
end;

procedure FreeLarge(h: PLargeHdr); inline;
begin
  InterLockedExchangeAdd64(gLiveBytes, -Int64(h^.Size));
  InterLockedDecrement64(gLiveCount);
  OSUnmap(h, h^.Size + SizeOf(TLargeHdr));
end;

{ ---- TMemoryManager hooks -------------------------------------------------- }

function OSGetMem(Size: PtrUInt): Pointer;
begin
  if Size >= LARGE_THRESHOLD then
  begin
    Result := OSAllocLarge(Size);
    if Result <> nil then Exit;     { else fall through to the underlying manager }
  end;
  Result := OldMM.GetMem(Size);
end;

function OSFreeMem(p: Pointer): PtrUInt;
var h: PLargeHdr;
begin
  h := OursHdr(p);
  if h <> nil then begin Result := h^.Size; FreeLarge(h); end
  else Result := OldMM.FreeMem(p);
end;

function OSFreeMemSize(p: Pointer; Size: PtrUInt): PtrUInt;
var h: PLargeHdr;
begin
  h := OursHdr(p);
  if h <> nil then begin Result := h^.Size; FreeLarge(h); end
  else Result := OldMM.FreeMemSize(p, Size);
end;

function OSAllocMem(Size: PtrUInt): Pointer;
begin
  if Size >= LARGE_THRESHOLD then
  begin
    Result := OSAllocLarge(Size);   { OS pages come zeroed -> no memset needed }
    if Result <> nil then Exit;
  end;
  Result := OldMM.AllocMem(Size);
end;

function OSMemSize(p: Pointer): PtrUInt;
var h: PLargeHdr;
begin
  h := OursHdr(p);
  if h <> nil then Result := h^.Size
  else Result := OldMM.MemSize(p);
end;

function OSReAllocMem(var p: Pointer; Size: PtrUInt): Pointer;
var h: PLargeHdr; np: Pointer; oldSize, copyN: PtrUInt;
begin
  if p = nil then begin Result := OSGetMem(Size); p := Result; Exit; end;
  if Size = 0 then begin OSFreeMem(p); p := nil; Result := nil; Exit; end;

  h := OursHdr(p);
  if h <> nil then
  begin
    { Currently an OS block. VirtualAlloc can't grow in place; allocate the new
      target (OS or, if it dropped below the threshold, the underlying manager),
      copy, release the old. }
    oldSize := h^.Size;
    np := OSGetMem(Size);
    if np = nil then begin Result := nil; Exit; end;   { OOM: leave p intact }
    if Size < oldSize then copyN := Size else copyN := oldSize;
    Move(p^, np^, copyN);
    FreeLarge(h);
    p := np; Result := np;
  end
  else if Size >= LARGE_THRESHOLD then
  begin
    { Was a small (underlying) block, now grows past the threshold: migrate to
      the OS so it can later be returned. }
    oldSize := OldMM.MemSize(p);
    np := OSAllocLarge(Size);
    if np = nil then begin Result := OldMM.ReAllocMem(p, Size); Exit; end;
    if Size < oldSize then copyN := Size else copyN := oldSize;
    Move(p^, np^, copyN);
    OldMM.FreeMem(p);
    p := np; Result := np;
  end
  else
    { Small -> small: leave it to the underlying manager. }
    Result := OldMM.ReAllocMem(p, Size);
end;

{ ---- install / public ------------------------------------------------------ }

procedure InstallOSLargeBlockManager;
var mm: TMemoryManager;
begin
  if Installed then Exit;
  GetMemoryManager(OldMM);
  mm := OldMM;                       { inherit InitThread/DoneThread/RelocateHeap/
                                       GetHeapStatus/GetFPCHeapStatus unchanged }
  mm.GetMem      := @OSGetMem;
  mm.FreeMem     := @OSFreeMem;
  mm.FreeMemSize := @OSFreeMemSize;
  mm.AllocMem    := @OSAllocMem;
  mm.ReAllocMem  := @OSReAllocMem;
  mm.MemSize     := @OSMemSize;
  SetMemoryManager(mm);
  Installed := True;
end;

function GetOSLargeBytes: PtrUInt;     begin Result := PtrUInt(gLiveBytes); end;
function GetOSLargeCount: PtrUInt;     begin Result := PtrUInt(gLiveCount); end;
function GetOSLargeThreshold: PtrUInt; begin Result := LARGE_THRESHOLD; end;

initialization
  InstallOSLargeBlockManager;

end.
