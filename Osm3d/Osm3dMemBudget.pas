unit Osm3dMemBudget;

{$mode objfpc}{$H+}

interface

const
  MEM_BUDGET_FRACTION = 0.6;   { норма: половина-две трети свободной }

procedure MemBudgetInit;
function ProcessRSSBytes: Int64;
function SystemFreeBytes: Int64;
function MemBudgetBytes: Int64;
{ True — пора эвиктить (RSS превысил бюджет). Опрос не чаще раза в ~2 с;
  между опросами возвращает последнее значение. }
function MemOverBudget: Boolean;

implementation

uses
  SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  ;

{$IFDEF WINDOWS}
type
  TProcessMemoryCounters = record
    cb: DWORD;
    PageFaultCount: DWORD;
    PeakWorkingSetSize, WorkingSetSize: PtrUInt;
    QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage: PtrUInt;
    QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage: PtrUInt;
    PagefileUsage, PeakPagefileUsage: PtrUInt;
  end;
function GetProcessMemoryInfo(Process: THandle;
  var Counters: TProcessMemoryCounters; cb: DWORD): BOOL; stdcall;
  external 'psapi.dll' name 'GetProcessMemoryInfo';

type
  { В юните Windows у FPC нет GlobalMemoryStatusEx — объявляем сами. }
  TMemoryStatusEx = record
    dwLength, dwMemoryLoad: DWORD;
    ullTotalPhys, ullAvailPhys: QWord;
    ullTotalPageFile, ullAvailPageFile: QWord;
    ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual: QWord;
  end;
function GlobalMemoryStatusEx(var Buffer: TMemoryStatusEx): BOOL; stdcall;
  external 'kernel32.dll' name 'GlobalMemoryStatusEx';
{$ENDIF}

var
  GBudget:    Int64 = 0;
  GLastOver:  Boolean = False;
  GLastTick:  QWord = 0;

{$IFDEF WINDOWS}
function ProcessRSSBytes: Int64;
var C: TProcessMemoryCounters;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1579);{$ENDIF}
  Result := 0;
  C.cb := SizeOf(C);
  if GetProcessMemoryInfo(GetCurrentProcess, C, SizeOf(C)) then
    Result := C.WorkingSetSize;
end;

function SystemFreeBytes: Int64;
var S: TMemoryStatusEx;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1580);{$ENDIF}
  Result := 0;
  S.dwLength := SizeOf(S);
  if GlobalMemoryStatusEx(S) then
    Result := S.ullAvailPhys;
end;
{$ELSE}
function ReadProcValueKB(const APath, AKey: string): Int64;
var
  F: TextFile;
  L: string;
  I: Integer;
  V: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1581);{$ENDIF}
  Result := 0;
  if not FileExists(APath) then Exit;
  AssignFile(F, APath);
  try
    Reset(F);
    while not Eof(F) do
    begin
      ReadLn(F, L);
      if Copy(L, 1, Length(AKey)) = AKey then
      begin
        V := '';
        for I := Length(AKey) + 1 to Length(L) do
          if L[I] in ['0'..'9'] then V := V + L[I]
          else if V <> '' then Break;
        Result := StrToInt64Def(V, 0) * 1024;
        Break;
      end;
    end;
  finally
    CloseFile(F);
  end;
end;

function ProcessRSSBytes: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1582);{$ENDIF}
  Result := ReadProcValueKB('/proc/self/status', 'VmRSS:');
end;

function SystemFreeBytes: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1583);{$ENDIF}
  Result := ReadProcValueKB('/proc/meminfo', 'MemAvailable:');
  if Result = 0 then
    Result := ReadProcValueKB('/proc/meminfo', 'MemFree:');
end;
{$ENDIF}

procedure MemBudgetInit;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1584);{$ENDIF}
  GBudget := ProcessRSSBytes + Round(SystemFreeBytes * MEM_BUDGET_FRACTION);
  if GBudget < 512 * 1024 * 1024 then
    GBudget := 512 * 1024 * 1024;   { нижний предохранитель }
end;

function MemBudgetBytes: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1585);{$ENDIF}
  if GBudget = 0 then MemBudgetInit;
  Result := GBudget;
end;

function MemOverBudget: Boolean;
var Now: QWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1586);{$ENDIF}
  Now := GetTickCount64;
  if (GLastTick = 0) or (Now - GLastTick >= 2000) then
  begin
    GLastTick := Now;
    GLastOver := ProcessRSSBytes > MemBudgetBytes;
  end;
  Result := GLastOver;
end;

end.
