unit GameMenuLayout;
{$mode objfpc}{$H+}
interface
type
  TMenuLayout = record
    Compact: Boolean;
    NavigationWidth, PageLeft, HeaderHeight, Margin: Single;
  end;
function MenuLayout(Width, Height: Single; TouchDevice, Session: Boolean): TMenuLayout;
function MenuInterfaceScale(Width, Height, Dpi, Preference: Single; TouchDevice: Boolean): Single;
implementation
uses Math;
function MenuInterfaceScale(Width, Height, Dpi, Preference: Single; TouchDevice: Boolean): Single;
begin
  { Do not squeeze a desktop canvas into a phone or a small window.
    Text stays legible; layout and scrolling handle the available space. }
  if TouchDevice then Result:=EnsureRange(Dpi/160,1.0,8.0)
  else Result:=EnsureRange(Dpi/96,1.0,8.0);
  Result:=Result*EnsureRange(Preference,1.0,1.5);
end;
function MenuLayout(Width, Height: Single; TouchDevice, Session: Boolean): TMenuLayout;
begin
  Result.Compact:=(Width<1180) or (Height<690);
  Result.Margin:=12;
  Result.NavigationWidth:=Min(272,Max(200,Width-48));
  if Result.Compact then begin
    Result.PageLeft:=8;
    if Width<660 then Result.HeaderHeight:=156 else Result.HeaderHeight:=108;
    if Session then Result.HeaderHeight:=Result.HeaderHeight+48;
  end else begin
    Result.NavigationWidth:=EnsureRange(Width*0.14,214,244);
    Result.PageLeft:=Result.NavigationWidth+16;
    if Session then Result.HeaderHeight:=160 else Result.HeaderHeight:=124;
  end;
end;
end.
