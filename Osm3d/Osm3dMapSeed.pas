unit Osm3dMapSeed;
{$mode objfpc}{$H+}
{ Read-only install data. One indexed file, bounded reads, no HTTP/cache writes.
  The resource stream also works for castle-data inside an Android APK. }
interface
uses CastleImages;
const MAP_SEED_RELIEF_ZOOM=8;
function BundledWorldMapTile(Z,X,Y:Integer;Relief:Boolean;out Quality:Integer):TCastleImage;
implementation
uses Classes,SysUtils,Math,SyncObjs,CastleDownload,CastleVectors,CastleLog,
  FPImage,FPReadPNG,FPReadJPEG;
type
  TEntry=packed record ColorOffset:QWord;ColorSize:LongWord;MaskOffset:QWord;MaskSize:LongWord;end;
var Guard:TCriticalSection;Pack:TStream;Entries:array of TEntry;
  MaxZoom:Integer;Attempted:Boolean;

procedure OpenPack;
var Magic:array[0..7]of Char;Z,Side,Count:LongWord;I:Integer;Start:QWord;
begin
  if Attempted then Exit;
  Attempted:=True;
  try
    Pack:=Download('castle-data:/map-overview/world.rzmap');
    Pack.ReadBuffer(Magic,8);
    if not CompareMem(@Magic[0],PChar('RZWMAP1'#0),8)or(Pack.Size>256*1024*1024)then raise Exception.Create('Invalid overview header');
    Pack.ReadBuffer(Z,4);Pack.ReadBuffer(Side,4);Pack.ReadBuffer(Count,4);
    Z:=LEtoN(Z);Side:=LEtoN(Side);Count:=LEtoN(Count);
    if(Z>7)or(Side<>256)or(Count<>((QWord(1)shl(2*(Z+1)))-1)div 3)then
      raise Exception.Create('Invalid overview index');
    Start:=20+QWord(Count)*SizeOf(TEntry);
    if Start>QWord(Pack.Size)then raise Exception.Create('Truncated overview index');
    SetLength(Entries,Count);Pack.ReadBuffer(Entries[0],Count*SizeOf(TEntry));
    for I:=0 to High(Entries)do with Entries[I]do begin
      ColorOffset:=LEtoN(ColorOffset);ColorSize:=LEtoN(ColorSize);
      MaskOffset:=LEtoN(MaskOffset);MaskSize:=LEtoN(MaskSize);
      if(ColorSize=0)or(ColorSize>262144)or(MaskSize=0)or(MaskSize>262144)or
        (ColorOffset<Start)or(MaskOffset<Start)or
        (ColorOffset>QWord(Pack.Size)-ColorSize)or(MaskOffset>QWord(Pack.Size)-MaskSize)then
        raise Exception.Create('Invalid overview payload');
    end;
    MaxZoom:=Z;
  except on E:Exception do begin
    WritelnLog('Map overview','Cannot open bundled atlas: '+E.Message);
    FreeAndNil(Pack);Entries:=nil;
  end end;
end;

function BundledWorldMapTile(Z,X,Y:Integer;Relief:Boolean;out Quality:Integer):TCastleImage;
var SZ,D,I,J,Idx,SX,SY,AX,AY,BX,BY:Integer;Data:TMemoryStream;Decoded:TFPMemoryImage;
  Reader:TFPCustomImageReader;E:TEntry;Size:LongWord;Offset:QWord;C:TVector3Byte;
  FX,FY,WX,WY:Double;CA,CB,CC,CD:TFPColor;
  function Mix(A,B,C,D:Word):Byte;
  begin Result:=EnsureRange(Round(((A*(1-WX)+B*WX)*(1-WY)+(C*(1-WX)+D*WX)*WY)/257),0,255);end;
begin
  Result:=nil;Quality:=0;
  if(Z<0)or(Z>24)or(X<0)or(Y<0)or(X>=(1 shl Z))or(Y>=(1 shl Z))then Exit;
  Data:=TMemoryStream.Create;Decoded:=nil;Reader:=nil;
  try
   try
    Guard.Enter;
    try
      OpenPack;if Pack=nil then Exit;
      SZ:=Min(Z,MaxZoom);Quality:=SZ;D:=1 shl(Z-SZ);
      Idx:=((1 shl(2*SZ))-1)div 3+(Y div D)*(1 shl SZ)+X div D;
      E:=Entries[Idx];
      if Relief then begin Size:=E.ColorSize;Offset:=E.ColorOffset;end
      else begin Size:=E.MaskSize;Offset:=E.MaskOffset;end;
      Data.SetSize(Size);Pack.Position:=Offset;Pack.ReadBuffer(Data.Memory^,Size);Data.Position:=0;
    finally Guard.Leave end;
    if Relief then Reader:=TFPReaderJPEG.Create else Reader:=TFPReaderPNG.Create;
    Decoded:=TFPMemoryImage.Create(0,0);Decoded.LoadFromStream(Data,Reader);
    if(Decoded.Width<>256)or(Decoded.Height<>256)then Exit;
    Result:=TRGBImage.Create(256,256);SX:=X mod D;SY:=Y mod D;
    for J:=0 to 255 do begin
      FY:=(SY*256+J+0.5)/D-0.5;AY:=EnsureRange(Floor(FY),0,255);BY:=Min(AY+1,255);WY:=EnsureRange(FY-AY,0.0,1.0);
      for I:=0 to 255 do begin
        FX:=(SX*256+I+0.5)/D-0.5;AX:=EnsureRange(Floor(FX),0,255);BX:=Min(AX+1,255);WX:=EnsureRange(FX-AX,0.0,1.0);
        CA:=Decoded.Colors[AX,AY];CB:=Decoded.Colors[BX,AY];CC:=Decoded.Colors[AX,BY];CD:=Decoded.Colors[BX,BY];
        if Relief then C:=Vector3Byte(Mix(CA.Red,CB.Red,CC.Red,CD.Red),Mix(CA.Green,CB.Green,CC.Green,CD.Green),Mix(CA.Blue,CB.Blue,CC.Blue,CD.Blue))
        else begin C.X:=Mix(CA.Red,CB.Red,CC.Red,CD.Red);C.Y:=C.X;C.Z:=C.X;end;
        PVector3Byte(Result.PixelPtr(I,255-J))^:=C;
      end;
    end;
   except FreeAndNil(Result) end;
  finally Reader.Free;Decoded.Free;Data.Free end;
end;
initialization Guard:=TCriticalSection.Create;
finalization Pack.Free;Entries:=nil;Guard.Free;
end.
