unit GameTrainingWindow;
{$mode objfpc}{$H+}
interface
uses CastleWindow, CastleKeysMouse {$ifdef MSWINDOWS}, Windows{$endif};
type
  { Temporarily reshape the existing native window. Do not toggle CGE
    FullScreen: that recreates its GL context on the WinAPI backend. }
  TTrainingWindow = class
  private
    FActive, FOnTop: Boolean;
    FWindow: TCastleWindow;
    FMinWidth, FMinHeight: Integer;
    FFullScreenKey: TKey;
    {$ifdef MSWINDOWS}
    FHandle: HWND;
    FPlacement: TWindowPlacement;
    FStyle, FExStyle: PtrInt;
    {$endif}
    procedure Restore;
  public
    destructor Destroy; override;
    procedure SetActive(const Value: Boolean);
    procedure SetOnTop(const Value: Boolean);
  end;

function TrainingFocusScale(const UIScale: Single): Single;

implementation
uses Math {$ifdef MSWINDOWS},MultiMon{$endif};
var PixelScale: Single = 1;

function TrainingFocusScale(const UIScale: Single): Single;
begin Result := Max(0.01, UIScale / PixelScale); end;

{$ifdef MSWINDOWS}
type
  TWindowLookup = record Target: TCastleWindow; Handle: HWND; end;
  PWindowLookup = ^TWindowLookup;
  TGetWindowDpi = function(W: HWND): UINT; stdcall;

function FindEngineWindow(W: HWND; Param: LPARAM): BOOL; stdcall;
begin
  Result := True;
  { CGE stores Self here; enumeration is confined to the current UI thread. }
  if GetWindowLongPtr(W, GWLP_USERDATA) = PtrInt(PWindowLookup(Param)^.Target) then
  begin PWindowLookup(Param)^.Handle := W; Result := False; end;
end;
{$endif}

procedure TTrainingWindow.SetActive(const Value: Boolean);
{$ifdef MSWINDOWS}
var Lookup: TWindowLookup; Monitor: TMonitorInfo; R: TRect;
    GetDpi: TGetWindowDpi; Width, Height, Margin: Integer;
{$endif}
begin
  if Value = FActive then Exit;
  if not Value then begin Restore; Exit; end;
  {$ifdef MSWINDOWS}
  Lookup.Target := Application.MainWindow; Lookup.Handle := 0;
  if (Lookup.Target = nil) or Lookup.Target.Closed then Exit;
  EnumThreadWindows(GetCurrentThreadId, @FindEngineWindow, LPARAM(@Lookup));
  if Lookup.Handle = 0 then Exit;
  FHandle := Lookup.Handle; FWindow := Lookup.Target;
  FillChar(FPlacement, SizeOf(FPlacement), 0); FPlacement.length := SizeOf(FPlacement);
  if not GetWindowPlacement(FHandle, @FPlacement) then Exit;
  FStyle := GetWindowLongPtr(FHandle, GWL_STYLE);
  FExStyle := GetWindowLongPtr(FHandle, GWL_EXSTYLE);
  FMinWidth := FWindow.MinWidth; FMinHeight := FWindow.MinHeight;
  FFullScreenKey := FWindow.SwapFullScreen_Key;
  Monitor.cbSize := SizeOf(Monitor);
  if not GetMonitorInfo(MonitorFromWindow(FHandle, MONITOR_DEFAULTTONEAREST), @Monitor) then Exit;
  PixelScale := 1;
  Pointer(GetDpi) := GetProcAddress(GetModuleHandle('user32.dll'), 'GetDpiForWindow');
  if Assigned(GetDpi) then PixelScale := Max(1, GetDpi(FHandle) / 96);
  PixelScale := Min(PixelScale, (Monitor.rcWork.Bottom-Monitor.rcWork.Top-64)/660);
  PixelScale := Max(0.65, PixelScale);
  FActive := True;
  FWindow.MinWidth := Round(360*PixelScale); FWindow.MinHeight := Round(660*PixelScale);
  FWindow.SwapFullScreen_Key := keyNone;
  if IsZoomed(FHandle) or IsIconic(FHandle) then ShowWindow(FHandle, SW_RESTORE);
  SetWindowLongPtr(FHandle, GWL_STYLE,
    (FStyle and not (WS_POPUP or WS_MAXIMIZE or WS_MINIMIZE)) or WS_OVERLAPPEDWINDOW);
  R.Left:=0; R.Top:=0; R.Right:=Round(360*PixelScale); R.Bottom:=Round(660*PixelScale);
  AdjustWindowRectEx(R, DWORD(GetWindowLongPtr(FHandle,GWL_STYLE)), False, DWORD(FExStyle));
  Width:=R.Right-R.Left; Height:=R.Bottom-R.Top; Margin:=Round(12*PixelScale);
  SetWindowPos(FHandle, HWND_NOTOPMOST, Monitor.rcWork.Right-Width-Margin,
    Monitor.rcWork.Bottom-Height-Margin, Width, Height, SWP_NOACTIVATE or SWP_FRAMECHANGED);
  SetOnTop(FOnTop);
  {$endif}
end;

procedure TTrainingWindow.SetOnTop(const Value: Boolean);
{$ifdef MSWINDOWS}var Order: HWND;{$endif}
begin
  FOnTop := Value;
  {$ifdef MSWINDOWS}
  if not FActive or not IsWindow(FHandle) then Exit;
  if Value then Order := HWND_TOPMOST else Order := HWND_NOTOPMOST;
  SetWindowPos(FHandle, Order, 0,0,0,0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  {$endif}
end;

procedure TTrainingWindow.Restore;
{$ifdef MSWINDOWS}var Order: HWND;{$endif}
begin
  if not FActive then Exit;
  FActive:=False; PixelScale:=1;
  {$ifdef MSWINDOWS}
  FWindow.MinWidth:=FMinWidth; FWindow.MinHeight:=FMinHeight;
  FWindow.SwapFullScreen_Key:=FFullScreenKey;
  if IsWindow(FHandle) then begin
    SetWindowLongPtr(FHandle,GWL_STYLE,FStyle);
    SetWindowLongPtr(FHandle,GWL_EXSTYLE,FExStyle);
    SetWindowPlacement(FHandle,@FPlacement);
    if (FExStyle and WS_EX_TOPMOST)<>0 then Order:=HWND_TOPMOST else Order:=HWND_NOTOPMOST;
    SetWindowPos(FHandle,Order,0,0,0,0,
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE or SWP_FRAMECHANGED);
  end;
  FHandle:=0; FWindow:=nil;
  {$endif}
end;

destructor TTrainingWindow.Destroy;
begin Restore; inherited; end;
end.
