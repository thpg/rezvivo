unit Osm3dMapillaryCoverage;
{$mode objfpc}{$H+}{$modeswitch advancedrecords}
{ Bounded MVT decoder for the public Mapillary image-point layer. No network,
  scene state, dependencies or loading metadata for every point in a tile. }
interface
uses SysUtils,Classes,fpjson;
function DecodeMapillaryCoverage(const Bytes:TBytes; Z,X,Y:Integer):TJSONArray;
implementation
uses Math;
type
  TProto=record
    Data:TBytes;Pos:SizeInt;
    function UInt:QWord;
    function Next(out Field,Wire:Integer;out Number:QWord;out Value:TBytes):Boolean;
  end;
  TByteArrays=array of TBytes;
function TProto.UInt:QWord;
var Shift:Integer;B:Byte;
begin
  Result:=0;Shift:=0;
  repeat
    if (Pos>=Length(Data)) or (Shift>63) then raise Exception.Create('Invalid MVT varint');
    B:=Data[Pos];Inc(Pos);if (Shift=63) and ((B and $7e)<>0) then raise Exception.Create('MVT integer overflow');
    Result:=Result or (QWord(B and 127) shl Shift);Inc(Shift,7);
  until B<128;
end;
function TProto.Next(out Field,Wire:Integer;out Number:QWord;out Value:TBytes):Boolean;
var Tag,N:QWord;
begin
  Result:=Pos<Length(Data);if not Result then Exit;
  Tag:=UInt;Field:=Tag shr 3;Wire:=Tag and 7;Number:=0;Value:=nil;
  if Field=0 then raise Exception.Create('Invalid MVT field');
  if Wire=0 then begin Number:=UInt;Exit end;
  case Wire of 1:N:=8;2:N:=UInt;5:N:=4;else raise Exception.Create('Unsupported MVT wire type') end;
  if N>QWord(Length(Data)-Pos) then raise Exception.Create('Truncated MVT field');
  Value:=Copy(Data,Pos,SizeInt(N));Inc(Pos,SizeInt(N));
end;
function Text(const B:TBytes):string;
begin if Length(B)=0 then Exit('');SetString(Result,PAnsiChar(@B[0]),Length(B)) end;
function Zig(N:QWord):Int64;
begin Result:=Int64(N shr 1);if (N and 1)<>0 then Result:=-Result-1 end;
function DecodeValue(const Bytes:TBytes):TJSONData;
var R:TProto;F,W:Integer;N:QWord;B:TBytes;V:Single;D:Double;
begin
  R.Data:=Bytes;R.Pos:=0;Result:=nil;
  while R.Next(F,W,N,B) do case F of
    1:Exit(TJSONString.Create(Text(B)));
    2:if Length(B)=4 then begin Move(B[0],V,4);if not IsNan(V) and not IsInfinite(V) then Exit(TJSONFloatNumber.Create(V)) end;
    3:if Length(B)=8 then begin Move(B[0],D,8);if not IsNan(D) and not IsInfinite(D) then Exit(TJSONFloatNumber.Create(D)) end;
    4,5:if N<=QWord(High(Int64)) then Exit(TJSONInt64Number.Create(Int64(N)));
    6:Exit(TJSONInt64Number.Create(Zig(N)));
    7:Exit(TJSONBoolean.Create(N<>0));
  end;
  Result:=TJSONNull.Create;
end;
procedure DecodeLayer(const Bytes:TBytes; Z,X,Y:Integer;Photos:TJSONArray);
var R,T,G:TProto;F,W,I,K,Index,GeometryType:Integer;N,KI,VI,Command:QWord;B,Tags,Geometry:TBytes;
  Name:string;Keys:TStringList;Values:TJSONArray;Features:TByteArrays;Extent,DX,DY:Int64;
  P:TJSONObject;Lat,Lon:Double;
begin
  R.Data:=Bytes;R.Pos:=0;Keys:=TStringList.Create;Values:=TJSONArray.Create;Extent:=4096;Name:='';Features:=nil;
  try
    while R.Next(F,W,N,B) do case F of
      1:Name:=Text(B);
      2:begin if Length(Features)>=100000 then raise Exception.Create('MVT feature limit exceeded');
        K:=Length(Features);SetLength(Features,K+1);Features[K]:=B end;
      3:begin if Keys.Count>=10000 then raise Exception.Create('MVT key limit exceeded');Keys.Add(Text(B)) end;
      4:begin if Values.Count>=500000 then raise Exception.Create('MVT value limit exceeded');Values.Add(DecodeValue(B)) end;
      5:begin if (N=0) or (N>1048576) then raise Exception.Create('Invalid MVT extent');Extent:=N end;
    end;
    if Name<>'image' then Exit;
    for I:=0 to High(Features) do begin
      T.Data:=Features[I];T.Pos:=0;Tags:=nil;Geometry:=nil;GeometryType:=0;
      while T.Next(F,W,N,B) do case F of 2:Tags:=B;3:GeometryType:=N;4:Geometry:=B end;
      if (GeometryType<>1) or (Length(Geometry)=0) then Continue;
      P:=TJSONObject.Create;
      try
        T.Data:=Tags;T.Pos:=0;
        while T.Pos<Length(T.Data) do begin
          KI:=T.UInt;VI:=T.UInt;
          if (KI>=QWord(Keys.Count)) or (VI>=QWord(Values.Count)) then raise Exception.Create('Invalid MVT property index');
          Index:=P.IndexOfName(Keys[KI]);if Index>=0 then P.Delete(Index);P.Add(Keys[KI],Values[VI].Clone);
        end;
        if P.Find('id')=nil then Continue;
        G.Data:=Geometry;G.Pos:=0;Command:=G.UInt;
        if ((Command and 7)<>1) or ((Command shr 3)<>1) then Continue;
        DX:=Zig(G.UInt);DY:=Zig(G.UInt);
        Lon:=(X+DX/Extent)/IntPower(2,Z)*360-180;
        Lat:=RadToDeg(ArcTan(Sinh(Pi*(1-2*(Y+DY/Extent)/IntPower(2,Z)))));
        P.Add('geometry',TJSONObject.Create(['type','Point','coordinates',TJSONArray.Create([Lon,Lat])]));
        if P.Find('sequence_id')<>nil then P.Add('sequence',P.Find('sequence_id').Clone);
        Photos.Add(P);P:=nil;
      finally P.Free end;
    end;
  finally Keys.Free;Values.Free end;
end;
function DecodeMapillaryCoverage(const Bytes:TBytes; Z,X,Y:Integer):TJSONArray;
var R:TProto;F,W:Integer;N:QWord;B:TBytes;
begin
  if (Length(Bytes)>32*1024*1024) or (Z<0) or (Z>20) or (X<0) or (Y<0) or
    (X>=Int64(1) shl Z) or (Y>=Int64(1) shl Z) then raise Exception.Create('Invalid coverage tile');
  Result:=TJSONArray.Create;R.Data:=Bytes;R.Pos:=0;
  try while R.Next(F,W,N,B) do if F=3 then DecodeLayer(B,Z,X,Y,Result)
  except Result.Free;raise end;
end;
end.
