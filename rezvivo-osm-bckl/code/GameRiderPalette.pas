unit GameRiderPalette;
{$mode objfpc}{$H+}
interface
uses CastleColors, CastleControls;
type
  TRiderPanelPalette = record
    FrameColor, Accent, Surface, DarkSurface, Border, TextColor,
      AccentTextColor: TCastleColor;
  end;
function RiderPanelPalette(ProfileIndex:Integer=0):TRiderPanelPalette;
function RiderPaletteSignature(ProfileIndex:Integer=0):String;
procedure ApplyRiderButtonPalette(Button:TCastleButton;ProfileIndex:Integer;
  Selected:Boolean=False);
procedure ApplyRiderMenuButtonPalette(Button:TCastleButton;ProfileIndex:Integer;
  Selected:Boolean=False);
implementation
uses SysUtils, Math, Classes, fpjson, jsonparser, CastleVectors,
  GameUserData, GameBikeAvatar;
type
  TPaletteCache=record
    Signature,Filename:String;
    Stamp:LongInt;
    Checked:QWord;
    Ready:Boolean;
    Palette:TRiderPanelPalette;
  end;
var Cache:array[0..7]of TPaletteCache;
function Mix(const A,B:TCastleColor;T:Single):TCastleColor;
begin
  Result:=Vector4(A.X+(B.X-A.X)*T,A.Y+(B.Y-A.Y)*T,
    A.Z+(B.Z-A.Z)*T,1);
end;
function RiderPanelPalette(ProfileIndex:Integer):TRiderPanelPalette;
var Index,N:Integer;Sig,Fn,Hex:String;Stamp:LongInt;NowTick:QWord;
  Data,Colors,Frame:TJSONData;SL:TStringList;C:TCastleColor;
begin
  Index:=EnsureRange(ProfileIndex,0,7);
  Sig:=RiderSettings(Index).SelectedBikeJson+'|'+RiderSettings(Index).BikeFitColors;
  NowTick:=GetTickCount64;
  if Cache[Index].Ready and(Cache[Index].Signature=Sig)and
    (NowTick-Cache[Index].Checked<1000)then Exit(Cache[Index].Palette);
  Fn:=BikeJsonUrlToFilename(ResolveActiveBikeBuildUrl(Index));
  Stamp:=FileAge(Fn);Cache[Index].Checked:=NowTick;
  if Cache[Index].Ready and(Cache[Index].Signature=Sig)and
    (Cache[Index].Filename=Fn)and(Cache[Index].Stamp=Stamp)then
    Exit(Cache[Index].Palette);
  C:=Vector4(0.72,0.08,0.04,1);
  Data:=nil;
  if Fn<>''then begin
    SL:=TStringList.Create;
    try
      try
        SL.LoadFromFile(Fn);Data:=GetJSON(SL.Text);
        Colors:=Data.FindPath('colors');
        if Colors<>nil then begin
          Frame:=Colors.FindPath('Frame');
          if(Frame<>nil)and(Frame.JSONType=jtArray)and(Frame.Count>=3)then
            C:=Vector4(EnsureRange(Frame.Items[0].AsFloat,0,1),
              EnsureRange(Frame.Items[1].AsFloat,0,1),
              EnsureRange(Frame.Items[2].AsFloat,0,1),1);
        end;
      except { A partial save retains a safe default until the next refresh. }
      end;
    finally Data.Free;SL.Free end;
  end;
  SL:=TStringList.Create;
  try
    SL.StrictDelimiter:=True;SL.Delimiter:=',';
    SL.DelimitedText:=RiderSettings(Index).BikeFitColors;
    if SL.Count>7 then begin
      Hex:=Trim(SL[7]);
      if(Length(Hex)=6)and TryStrToInt('$'+Hex,N)then
        C:=Vector4(((N shr 16)and 255)/255,((N shr 8)and 255)/255,(N and 255)/255,1);
    end;
  finally SL.Free end;
  Result.FrameColor:=C;
  Result.Surface:=Mix(Vector4(1,1,1,1),C,0.14);
  Result.DarkSurface:=Mix(Vector4(0.045,0.055,0.065,1),C,0.22);
  Result.Border:=Mix(Vector4(1,1,1,1),C,0.55);
  Result.Accent:=Mix(C,Vector4(0,0,0,1),0.58);
  Result.TextColor:=Vector4(0.045,0.065,0.09,1);
  Result.AccentTextColor:=Vector4(1,1,1,1);
  with Cache[Index]do begin
    Signature:=Sig;Filename:=Fn;
    Palette:=Result;Ready:=True;
  end;
  Cache[Index].Stamp:=Stamp;
end;
function RiderPaletteSignature(ProfileIndex:Integer):String;
var P:TRiderPanelPalette;I:Integer;
begin
  I:=EnsureRange(ProfileIndex,0,7);P:=RiderPanelPalette(I);
  Result:=Cache[I].Signature+'|'+Cache[I].Filename+'|'+IntToStr(Cache[I].Stamp);
end;
procedure ApplyRiderButtonPalette(Button:TCastleButton;ProfileIndex:Integer;Selected:Boolean);
var P:TRiderPanelPalette;
begin
  if Button=nil then Exit;
  P:=RiderPanelPalette(ProfileIndex);
  Button.CustomBackground:=True;
  if Selected then Button.CustomColorNormal:=P.Accent
  else Button.CustomColorNormal:=P.DarkSurface;
  Button.CustomColorFocused:=Mix(P.Accent,Vector4(1,1,1,1),0.04);
  Button.CustomColorPressed:=P.Accent;
  Button.CustomTextColorUse:=True;
  Button.CustomTextColor:=P.AccentTextColor;
end;
procedure ApplyRiderMenuButtonPalette(Button:TCastleButton;ProfileIndex:Integer;Selected:Boolean);
var P:TRiderPanelPalette;
begin
  if Button=nil then Exit;
  P:=RiderPanelPalette(ProfileIndex);
  Button.CustomBackground:=True;
  if Selected then Button.CustomColorNormal:=Mix(P.Surface,P.FrameColor,0.17)
  else Button.CustomColorNormal:=P.Surface;
  Button.CustomColorFocused:=Mix(P.Surface,P.FrameColor,0.12);
  Button.CustomColorPressed:=Mix(P.Surface,P.FrameColor,0.17);
  Button.CustomTextColorUse:=True;
  Button.CustomTextColor:=P.TextColor;
end;
end.
