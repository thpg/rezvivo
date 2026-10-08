program McpLargeJsonTests;
{$mode objfpc}{$H+}{$codepage UTF8}
uses Osm3dOSHeap,Classes,SysUtils,fpjson,jsonparser,McpJsonString;
{$I ../../Mcp/Utf8Json.inc}
var S,Encoded,Chunk:UTF8String; A,B,C:TJSONData; I,J:Integer; Started:QWord;
procedure Check(OK:Boolean;const Msg:string);
begin if not OK then raise Exception.Create(Msg) end;
begin
  S:='';for I:=0 to 127 do S:=S+Char(I);
  S:=S+'Русский / 日本語 / emoji '+UTF8Encode(WideChar($D83D)+WideChar($DEB2));
  for J:=0 to 1 do begin
    TJSONString.StrictEscaping:=J=1;
    A:=TJSONString.Create(S);B:=TMcpJSONString.Create(S);
    try
      if A.AsJSON<>B.AsJSON then begin WriteLn('expected=',A.AsJSON);WriteLn('actual=',B.AsJSON) end;
      Check(A.AsJSON=B.AsJSON,'Standard escaping differs');
      C:=B.Clone;
      try Check(C.AsJSON=A.AsJSON,'Clone lost escaping') finally C.Free end;
    finally A.Free;B.Free end;
  end;
  TJSONString.StrictEscaping:=False;
  Chunk:='{"id":"way/123","text":"Русский and quotes \" ","n":17}'+#10;
  SetLength(S,Length(Chunk)*24000);
  for I:=0 to 23999 do Move(Chunk[1],S[I*Length(Chunk)+1],Length(Chunk));
  A:=TMcpJSONString.Create(S);
  try
    Started:=GetTickCount64;Encoded:=A.AsJSON;
    WriteLn('escape_ms=',GetTickCount64-Started,' bytes=',Length(Encoded));
    Check(GetTickCount64-Started<2500,'Large escape is no longer linear');
    B:=ParseUtf8Json(Encoded);
    try Check(B.AsString=S,'Large text did not round-trip') finally B.Free end;
  finally A.Free end;
  Chunk:='\u0420\u0443\u0441\u0441\u043a\u0438\u0439 \u65e5\u672c \uD83D\uDEB2';
  S:='"';for I:=1 to 1024 do S:=S+Chunk;S:=S+'"';
  Chunk:='Русский 日本 '+UTF8Encode(WideChar($D83D)+WideChar($DEB2));
  SetLength(Encoded,Length(Chunk)*1024);
  for I:=0 to 1023 do Move(Chunk[1],Encoded[I*Length(Chunk)+1],Length(Chunk));
  SetCodePage(RawByteString(Encoded),CP_UTF8,False);
  Started:=GetTickCount64;A:=ParseUtf8Json(S);
  try
    Check(A.AsString=Encoded,'Escaped multilingual text');
    WriteLn('unicode_parse_ms=',GetTickCount64-Started);
  finally A.Free end;
  for I:=0 to 1 do begin
    if I=0 then S:='"\uD83D"' else S:='"\uDEB2"';
    B:=nil;
    try
      try B:=ParseUtf8Json(S) except on E:Exception do Continue end;
      raise Exception.Create('Unpaired surrogate accepted');
    finally B.Free end;
  end;
  WriteLn('PASS MCP JSON escaping, clone, large payload, UTF-8 and surrogate checks');
end.
