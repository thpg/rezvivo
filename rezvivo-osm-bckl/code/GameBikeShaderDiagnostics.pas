unit GameBikeShaderDiagnostics;
{$mode objfpc}{$H+}
interface
uses BikeParametric,fpjson;
{ Explicit MCP snapshot only. Never called from the frame loop. }
function BikeShaderDiagnostics(Bike:TBikeInstance):TJSONObject;
implementation
uses Classes,SysUtils,CastleScene,CastleSceneInternalShape,CastleInternalRenderer,
  CastleShapes,CastleRenderOptions;
function BikeShaderDiagnostics(Bike:TBikeInstance):TJSONObject;
var Seen,Programs:TList;Scenes,Rows:TJSONArray;I,J:Integer;S:TCastleScene;
  Shape:TGLShape;P:TObject;
  procedure Scan(Scene:TCastleScene);
  var K:Integer;Pass:TTotalRenderingPass;
  begin
    if(Scene=nil)or(Scene.Shapes=nil)or(Seen.IndexOf(Scene)>=0)then Exit;
    Seen.Add(Scene);Scenes.Add(Scene.Name);
    for K:=0 to Scene.Shapes.TraverseList(False,False).Count-1 do begin
      Shape:=TGLShape(Scene.Shapes.TraverseList(False,False)[K]);
      for Pass:=Low(Pass)to High(Pass)do if Shape.ProgramCache[Pass]<>nil then begin
        P:=Shape.ProgramCache[Pass].ShaderProgram;
        if Programs.IndexOf(P)<0 then Programs.Add(P);
      end;
    end;
  end;
begin
  Result:=TJSONObject.Create;Rows:=TJSONArray.Create;Scenes:=TJSONArray.Create;
  Result.Add('programs',Rows);Result.Add('scenes',Scenes);
  Seen:=TList.Create;Programs:=TList.Create;
  try
    if Bike<>nil then begin
      Scan(Bike.RiderScene);
      for I:=0 to BSG_COUNT-1 do begin S:=Bike.SubScene(I);Scan(S) end;
    end;
    for J:=0 to Programs.Count-1 do Rows.Add(IntToHex(PtrUInt(Programs[J]),16));
    Result.Add('unique_programs',Programs.Count);
  finally Programs.Free;Seen.Free end;
end;
end.
