unit TreeBark;
{$mode objfpc}{$H+}
interface
const BARK_TEXTURE_SIZE=1024; BARK_TEXTURE_LAYERS=8;
type TBarkPixels=array of Byte;
function LoadBarkLayer(const Directory:string; Layer:Integer):TBarkPixels;
implementation
uses Classes,SysUtils,Math,FPImage,FPReadJPEG{$ifdef ANDROID},CastleDownload{$endif};
function LoadBarkLayer(const Directory:string; Layer:Integer):TBarkPixels;
const Names:array[0..3]of string=('jolcham_oak_bark_01','pine_bark','bark_willow','trident_maple_bark');
var Img:TFPMemoryImage;Reader:TFPReaderJPEG;Path:string;Stream:TStream;
  X,Y,I,SX,SY,SY2:Integer;C,D:TFPColor;Linear:array[0..255]of Byte;
  function Channel(A,B:Word):Byte;
  begin Result:=((LongWord(A)+B) div 2) shr 8;if Layer<4 then Result:=Linear[Result];end;
begin
  Result:=nil;
  if (Layer<0) or (Layer>=BARK_TEXTURE_LAYERS) then raise ERangeError.Create('Invalid bark layer');
  Path:=IncludeTrailingPathDelimiter(Directory)+Names[Layer mod 4];
  if Layer<4 then Path:=Path+'-Diffuse.jpg' else Path:=Path+'-nor_gl.jpg';
  Img:=TFPMemoryImage.Create(0,0);Reader:=TFPReaderJPEG.Create;Stream:=nil;
  try
    {$ifdef ANDROID}Stream:=Download(Path);{$else}Stream:=TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite);{$endif}
    Img.LoadFromStream(Stream,Reader);
    if (Img.Width<>BARK_TEXTURE_SIZE) or ((Img.Height<>BARK_TEXTURE_SIZE) and (Img.Height<>BARK_TEXTURE_SIZE*2)) then
      raise Exception.Create('Unexpected bark texture size: '+Path);
    for I:=0 to 255 do Linear[I]:=Round(Power(I/255,2.2)*255);
    SetLength(Result,BARK_TEXTURE_SIZE*BARK_TEXTURE_SIZE*4);
    for Y:=0 to BARK_TEXTURE_SIZE-1 do for X:=0 to BARK_TEXTURE_SIZE-1 do begin
      SX:=X;SY:=(BARK_TEXTURE_SIZE-1-Y)*Img.Height div BARK_TEXTURE_SIZE;
      SY2:=SY+Ord(Img.Height>BARK_TEXTURE_SIZE);
      C:=Img.Colors[SX,SY];D:=Img.Colors[SX,SY2];I:=(Y*BARK_TEXTURE_SIZE+X)*4;
      Result[I]:=Channel(C.Red,D.Red);Result[I+1]:=Channel(C.Green,D.Green);
      Result[I+2]:=Channel(C.Blue,D.Blue);Result[I+3]:=255;
    end;
  finally Stream.Free;Reader.Free;Img.Free;end;
end;
end.
