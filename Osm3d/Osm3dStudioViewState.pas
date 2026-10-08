unit Osm3dStudioViewState;
{$mode objfpc}{$H+}
interface
uses CastleVectors, Osm3dGeoMath;
type
  TStudioViewState = record
    HasView, FlatMode, HasStream, Has3DView, ProceduralTrees, ImpostorCache, RtxShadows, ShadowProjections,RtxReflections:Boolean;
    Origin, FlatOrigin:TLatLon;
    Position,Direction,Up,Position3D,Direction3D,Up3D:TVector3;
    RouteFile:string;
  end;
function StudioViewStatePath:string;
function LoadStudioViewState(const Path:string):TStudioViewState;
procedure SaveStudioViewState(const Path:string;const State:TStudioViewState);
implementation
uses Classes, SysUtils, Math, fpjson, jsonparser;
function StudioViewStatePath:string;
begin
  Result:=GetEnvironmentVariable('REZVIVO_STUDIO_STATE_FILE');
  if Result='' then begin
    Result:=GetEnvironmentVariable('LOCALAPPDATA');
    if Result='' then Result:=GetAppConfigDir(False);
    Result:=IncludeTrailingPathDelimiter(Result)+'REZVIVO'+PathDelim+'Osm3dStudio'+PathDelim+'view.json';
  end;
end;
function ValidVector(const V:TVector3):Boolean;
var I:Integer;
begin
  Result:=False;
  for I:=0 to 2 do if IsNan(V.Data[I]) or IsInfinite(V.Data[I]) or (Abs(V.Data[I])>1e8) then Exit;
  Result:=True;
end;
function ValidView(const P,D,U:TVector3):Boolean;
begin
  Result:=ValidVector(P) and ValidVector(D) and ValidVector(U) and
    (D.Length>0.0001) and (U.Length>0.0001) and (TVector3.CrossProduct(D,U).Length>0.0001);
end;
function LoadStudioViewState(const Path:string):TStudioViewState;
var J:TJSONData;O:TJSONObject;Lines:TStringList;
  function V(const Key:string):TVector3;
  var A:TJSONData;I:Integer;
  begin
    Result:=TVector3.Zero;A:=O.Find(Key);
    if (A=nil) or (A.JSONType<>jtArray) or (A.Count<>3) then Exit;
    for I:=0 to 2 do Result.Data[I]:=A.Items[I].AsFloat;
  end;
  function LL(const Key:string):TLatLon;
  var A:TJSONData;
  begin
    A:=O.Find(Key);
    if (A=nil) or (A.JSONType<>jtArray) or (A.Count<>2) then raise Exception.Create('Missing map origin');
    Result:=TLatLon.Make(A.Items[0].AsFloat,A.Items[1].AsFloat);
    if IsNan(Result.Lat) or IsInfinite(Result.Lat) or IsNan(Result.Lon) or IsInfinite(Result.Lon) or
      (Abs(Result.Lat)>90) or (Abs(Result.Lon)>180) then raise Exception.Create('Invalid map origin');
  end;
begin
  Result:=Default(TStudioViewState);Result.ProceduralTrees:=True;Result.ShadowProjections:=True;
  if not FileExists(Path) then Exit;
  J:=nil;Lines:=TStringList.Create;
  try
    try
      Lines.LoadFromFile(Path);J:=GetJSON(Lines.Text);
      if not (J is TJSONObject) then Exit;O:=TJSONObject(J);
      if O.Get('version',0)<>1 then Exit;
      Result.ProceduralTrees:=O.Get('procedural_trees',True);
      Result.ImpostorCache:=O.Get('impostor_cache',False);
      Result.RtxShadows:=O.Get('rtx_shadows',False);
      Result.RtxReflections:=O.Get('rtx_reflections',False);
      Result.ShadowProjections:=O.Get('shadow_projections',True) and not Result.RtxShadows;
      Result.FlatMode:=O.Get('flat',True);Result.HasStream:=O.Get('stream',False);
      Result.RouteFile:=O.Get('route','');Result.Origin:=LL('origin');Result.FlatOrigin:=LL('flat_origin');
      Result.Position:=V('position');Result.Direction:=V('direction');Result.Up:=V('up');
      Result.HasView:=O.Get('has_view',False) and ValidView(Result.Position,Result.Direction,Result.Up);
      Result.Position3D:=V('position_3d');Result.Direction3D:=V('direction_3d');Result.Up3D:=V('up_3d');
      Result.Has3DView:=O.Get('has_3d_view',False) and ValidView(Result.Position3D,Result.Direction3D,Result.Up3D);
    except Result.HasView:=False;Result.Has3DView:=False;end;
  finally J.Free;Lines.Free;end;
end;
procedure SaveStudioViewState(const Path:string;const State:TStudioViewState);
var O:TJSONObject;Lines:TStringList;
  procedure A(const Key:string;const Values:array of Double);
  var Arr:TJSONArray;I:Integer;
  begin
    Arr:=TJSONArray.Create;
    { Bypass the host's optional rounded JSON float factory. }
    for I:=0 to High(Values) do Arr.Add(TJSONFloatNumber.Create(Values[I]));
    O.Add(Key,Arr);
  end;
begin
  O:=TJSONObject.Create;Lines:=TStringList.Create;
  try
    O.Add('version',1);O.Add('has_view',State.HasView);O.Add('flat',State.FlatMode);
    O.Add('stream',State.HasStream);O.Add('procedural_trees',State.ProceduralTrees);O.Add('route',State.RouteFile);
    O.Add('impostor_cache',State.ImpostorCache);
    O.Add('rtx_shadows',State.RtxShadows);
    O.Add('rtx_reflections',State.RtxReflections);
    O.Add('shadow_projections',State.ShadowProjections);
    A('origin',[State.Origin.Lat,State.Origin.Lon]);A('flat_origin',[State.FlatOrigin.Lat,State.FlatOrigin.Lon]);
    A('position',[State.Position.X,State.Position.Y,State.Position.Z]);
    A('direction',[State.Direction.X,State.Direction.Y,State.Direction.Z]);A('up',[State.Up.X,State.Up.Y,State.Up.Z]);
    O.Add('has_3d_view',State.Has3DView);A('position_3d',[State.Position3D.X,State.Position3D.Y,State.Position3D.Z]);
    A('direction_3d',[State.Direction3D.X,State.Direction3D.Y,State.Direction3D.Z]);A('up_3d',[State.Up3D.X,State.Up3D.Y,State.Up3D.Z]);
    ForceDirectories(ExtractFilePath(ExpandFileName(Path)));Lines.Text:=O.FormatJSON;Lines.SaveToFile(Path);
  finally O.Free;Lines.Free;end;
end;
end.
