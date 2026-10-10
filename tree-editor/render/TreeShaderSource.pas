unit TreeShaderSource;
{$mode objfpc}{$H+}
{$ifdef ANDROID}{$define OpenGLES}{$endif}
interface
function RenderShaderSource(const Source: string; GLES: Boolean): string;
function ReadRenderShader(const Url: string): string;
implementation
uses Classes, SysUtils{$ifdef ANDROID}, CastleDownload{$endif};
function RenderShaderSource(const Source: string; GLES: Boolean): string;
begin
  Result := Source;
  if not GLES then Exit;
    Result := StringReplace(Result, '#version 330 core', '#version 300 es' + #10 +
      'precision highp float;' + #10 + 'precision highp int;' + #10 +
      'precision highp sampler2DArray;' + #10 +
      'precision highp sampler2DShadow;', []);
end;
function ReadRenderShader(const Url: string): string;
var S: TStringList;
{$ifdef ANDROID}Stream: TStream;{$endif}
begin
  S := TStringList.Create;
  try
    {$ifdef ANDROID}
    Stream := Download(Url);
    try S.LoadFromStream(Stream); finally Stream.Free end;
    {$else}S.LoadFromFile(Url);{$endif}
    Result := S.Text;
  finally S.Free end;
end;
end.
