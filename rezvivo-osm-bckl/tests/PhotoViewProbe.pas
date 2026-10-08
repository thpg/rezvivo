program PhotoViewProbe;
{$mode objfpc}{$H+}{$codepage UTF8}
uses Classes, SysUtils, fpjson, Osm3dPhotoSources, Osm3dPhotoView;
var L:TStringList; R,J:TJSONObject;
begin
  try
    L:=TStringList.Create;
    try L.LoadFromFile(ParamStr(1)); J:=TJSONObject(ParsePhotoJson(L.Text)) finally L.Free end;
    R:=nil;
    try
      if J.Get('action','project')='solve' then R:=SolvePhotoView(J)
      else R:=ProjectPhotoView(TJSONObject(J.Find('view')));
      WriteLn(R.AsJSON);
    finally R.Free; J.Free end;
  except on E:Exception do begin R:=TJSONObject.Create(['error',E.Message]); WriteLn(R.AsJSON); R.Free; Halt(1) end end;
end.
