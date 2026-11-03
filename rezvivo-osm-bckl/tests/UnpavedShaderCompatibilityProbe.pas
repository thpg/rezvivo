program UnpavedShaderCompatibilityProbe;
{$mode objfpc}{$H+}
{ Compile the complete production fragment and page functions for desktop
  GLSL and GLSL ES 3.0 on the driver; rendering is covered by the visual probe. }
uses SysUtils, Classes, CastleWindow, CastleApplicationProperties, CastleGLShaders,
  Osm3dGroundComposite, Osm3dRoadMaterial;
var W:TCastleWindow;P:TGLSLProgram;F,Header,Name:string;ES,Bake:Boolean;L:TStringList;
begin
  ApplicationProperties.ApplicationName:='REZVIVOUnpavedShaderCompatibility';
  W:=TCastleWindow.Create(nil);
  try
    W.Visible:=False;W.Width:=32;W.Height:=32;W.Open;
    for ES:=False to True do for Bake:=False to True do begin
      if ES then Header:='#version 300 es'+#10+'precision highp float; precision highp int;'+#10+
        'precision highp sampler2DShadow;'+#10
      else Header:='#version 330 core'+#10;
      Header+= '#define varying in'+#10+'#define texture2D texture'+#10;
      if Bake then F:=RoadMaterialGLSL+#10+
        'layout(location=0) out vec4 outColor;'+#10+
        'void main(){vec3 r;vec2 g;rp_surfaceGradient(gl_FragCoord.xy,17.,.02,vec3(4.,0.,0.),3.,3.,outColor,r,g);}'
      else F:='vec4 position_eye_to_world_space(vec4 p){return p;}'+#10+
        'vec3 direction_world_to_eye_space(vec3 p){return p;}'+#10+
        GROUND_COMPOSITE_FS+#10+'layout(location=0) out vec4 outColor;'+#10+
        'void main(){outColor=vec4(0.);PLUG_main_texture_apply(outColor,vec3(0.,1.,0.));'+
        'PLUG_fragment_modify(outColor);PLUG_fragment_end(outColor);}';
      Name:=Format('ground-es%d-bake%d',[Ord(ES),Ord(Bake)]);
      if ParamCount>0 then begin
        L:=TStringList.Create;try L.Text:=Header+F;L.SaveToFile(IncludeTrailingPathDelimiter(ParamStr(1))+Name+'.frag');finally L.Free end;
      end;
      P:=TGLSLProgram.Create;try P.AttachFragmentShader(Header+F);finally P.Free end;
      Writeln('PASS ',Name);
    end;
  finally W.Free end;
end.
