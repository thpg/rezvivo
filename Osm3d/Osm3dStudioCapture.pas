unit Osm3dStudioCapture;
{$mode objfpc}{$H+}
{ Paint the real LCL controls without showing or activating the test window.
  Hidden controls may have no native HWND yet; external PrintWindow alone
  consequently returns a black image. The GL viewport is captured separately. }
interface
uses Controls,Forms;
procedure CaptureStudioControls(Form:TCustomForm;Skip:TControl;const Path:string);
implementation
uses SysUtils,Graphics,LMessages,LCLIntf,WSControls;
type TControlAccess=class(TControl);
procedure CaptureStudioControls(Form:TCustomForm;Skip:TControl;const Path:string);
var Bitmap:TBitmap;Png:TPortableNetworkGraphic;
  procedure Prepare(Control:TControl);
  var I:Integer;Window:TWinControl;
  begin
    if (Control=Skip) or ((Control<>Form) and not Control.Visible) then Exit;
    if Control is TWinControl then begin
      Window:=TWinControl(Control);Window.HandleNeeded;
      if Control<>Form then TWSWinControlClass(Window.WidgetSetClass).SetBounds(Window,
        Window.Left,Window.Top,Window.Width,Window.Height);
      for I:=0 to Window.ControlCount-1 do Prepare(Window.Controls[I]);
    end;
  end;
  procedure Paint(Control:TControl;X,Y:Integer);
  var State,PaintState,I:Integer;Window:TWinControl;
  begin
    if (Control=Skip) or (Control.Width<=0) or (Control.Height<=0) then Exit;
    if (Control<>Form) and not Control.Visible then Exit;
    State:=SaveDC(Bitmap.Canvas.Handle);
    try
      MoveWindowOrgEx(Bitmap.Canvas.Handle,X,Y);
      IntersectClipRect(Bitmap.Canvas.Handle,0,0,Control.Width,Control.Height);
      PaintState:=SaveDC(Bitmap.Canvas.Handle);
      try
        if Control is TWinControl then begin
          Window:=TWinControl(Control);Window.HandleNeeded;
          Bitmap.Canvas.Brush.Color:=TControlAccess(Control).Color;
          Bitmap.Canvas.FillRect(0,0,Control.Width,Control.Height);
          if not (Control is TCustomControl) then begin
            SendMessage(Window.Handle,$0317,Bitmap.Canvas.Handle,4 or 8);
          end else begin
            Window.Perform(LM_ERASEBKGND,Bitmap.Canvas.Handle,0);
            Window.Perform(LM_PAINT,Bitmap.Canvas.Handle,0);
          end;
        end else Control.Perform(LM_PAINT,Bitmap.Canvas.Handle,0);
      finally RestoreDC(Bitmap.Canvas.Handle,PaintState) end;
      if Control is TWinControl then begin
        Window:=TWinControl(Control);
        for I:=0 to Window.ControlCount-1 do Paint(Window.Controls[I],Window.Controls[I].Left,Window.Controls[I].Top);
      end;
    finally RestoreDC(Bitmap.Canvas.Handle,State) end;
  end;
begin
  if (Path='') or (LowerCase(ExtractFileExt(Path))<>'.png') then raise Exception.Create('PNG capture path required');
  if FileExists(Path) then raise Exception.Create('Capture file already exists');
  Bitmap:=TBitmap.Create;Png:=TPortableNetworkGraphic.Create;
  try
    Prepare(Form);Bitmap.SetSize(Form.ClientWidth,Form.ClientHeight);
    Bitmap.Canvas.Brush.Color:=Form.Color;Bitmap.Canvas.FillRect(0,0,Bitmap.Width,Bitmap.Height);
    Paint(Form,0,0);Png.Assign(Bitmap);Png.SaveToFile(Path);
  finally Png.Free;Bitmap.Free end;
end;
end.
