unit TreeShaderSource;
{$mode objfpc}{$H+}
{$ifdef ANDROID}{$define OpenGLES}{$endif}
interface
function RenderShaderSource(const Source: string; GLES: Boolean): string;
function ReadRenderShader(const Url: string): string;
implementation
uses Classes, SysUtils, VegetationAtlas{$ifdef ANDROID}, CastleDownload{$endif};
function RenderShaderSource(const Source: string; GLES: Boolean): string;
var Extensions:string;
begin
  Result := StringReplace(Source,'/*__VEGETATION_CARD_ENVELOPE__*/',CardEnvelopeGLSL,[rfReplaceAll]);
  if not GLES then Exit;
  Extensions:='';
  if Pos('TREE_SAMPLE_MASK',Source)>0 then
    Extensions:='#ifdef GL_OES_sample_variables'+#10+
      '#extension GL_OES_sample_variables : enable'+#10+'#endif'+#10;
  Result := StringReplace(Result, '#version 330 core', '#version 300 es' + #10 + Extensions +
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
