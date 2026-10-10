unit GameDisplayMetrics;
{$mode objfpc}{$H+}
interface
uses CastleUIControls;
function DisplayUiDpi(Container:TCastleContainer):Single;
implementation
uses SysUtils,Math
  {$ifdef ANDROID},GameAndroidPlatform{$endif}
  {$ifdef MSWINDOWS},Windows,MultiMon,CastleWindow{$endif};
{$ifdef MSWINDOWS}
type
  PWindowHandle=^HWND;
  TMonitorDpi=function(Monitor:HMONITOR;Kind:Integer;out X,Y:UINT):HRESULT;stdcall;
  TWindowDpi=function(Window:HWND):UINT;stdcall;
var LastCheck:QWord=0;CachedDpi:Single=96;DpiLibrary:HMODULE=0;
  MonitorDpi:TMonitorDpi=nil;WindowDpi:TWindowDpi=nil;Initialized:Boolean=False;
function FindWindow(W:HWND;Param:LPARAM):BOOL;stdcall;
begin
  Result:=True;
  if GetWindowLongPtr(W,GWLP_USERDATA)=PtrInt(Application.MainWindow) then begin
    PWindowHandle(Param)^:=W;Result:=False;
  end;
end;
{$endif}
function DisplayUiDpi(Container:TCastleContainer):Single;
{$ifdef MSWINDOWS}
var W:HWND;X,Y:UINT;Tick:QWord;Folder:array[0..MAX_PATH]of WideChar;
{$endif}
begin
  Result:=Container.Dpi;
  {$ifdef ANDROID}Result:=AndroidPhysicalDpi;{$endif}
  {$ifdef MSWINDOWS}
  Tick:=GetTickCount64;
  if (LastCheck=0) or (Tick-LastCheck>=1000) then begin
    LastCheck:=Tick;CachedDpi:=Container.Dpi;
    if not Initialized then begin
      Initialized:=True;
      if GetSystemDirectoryW(Folder,Length(Folder))>0 then
        DpiLibrary:=LoadLibraryW(PWideChar(UnicodeString(Folder)+'\shcore.dll'));
      if DpiLibrary<>0 then Pointer(MonitorDpi):=GetProcAddress(DpiLibrary,'GetDpiForMonitor');
      Pointer(WindowDpi):=GetProcAddress(GetModuleHandle('user32.dll'),'GetDpiForWindow');
    end;
    W:=0;EnumThreadWindows(GetCurrentThreadId,@FindWindow,LPARAM(@W));
    if W<>0 then begin
      { MDT_RAW_DPI follows the monitor's physical dimensions, not window
        resolution. Respect larger accessibility scaling chosen in Windows. }
      if Assigned(MonitorDpi) and
        (MonitorDpi(MonitorFromWindow(W,MONITOR_DEFAULTTONEAREST),2,X,Y)=0) and
        (X>=60) and (X<=1000) and (Y>=60) and (Y<=1000) then
        CachedDpi:=Math.Max(CachedDpi,Single((X+Y)*0.5));
      if Assigned(WindowDpi) then CachedDpi:=Math.Max(CachedDpi,Single(WindowDpi(W)));
    end;
  end;
  Result:=CachedDpi;
  {$endif}
end;
end.
