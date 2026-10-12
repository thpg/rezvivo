program StreetLampTests;
{$mode objfpc}{$H+}
uses Classes,SysUtils,Math,fpjson,CastleVectors,Osm3dStreetLamps,Osm3dGeomMesh,
  Osm3dGeomPOI,Osm3dEnvironmentLayout,Osm3dPhotoSources,Osm3dOsmData,
  Osm3dTileX3D,Osm3dTileBinary,Osm3dGeoMath,Osm3dGeoTileGrid,Osm3dSceneMaterials;
var Style:TStreetLampStyle;M,L,B:TMesh;I,Checks:Integer;V:TMeshVertex;
  Lo,Hi:Single;Tags:TOSMTags;O:TJSONObject;S:string;
  Model,Loaded:TTileModel;Stream:TMemoryStream;Failed:Boolean;Folder:string;
procedure Check(OK:Boolean;const Msg:string);
begin if not OK then raise Exception.Create(Msg);Inc(Checks) end;
procedure Geometry(M:TMesh);
var I:Integer;A,C,D:TMeshVertex;Cross,N:TVector3;
begin
  Check(M.VertexCount>0,'empty mesh');Check(M.TriangleCount<400,'triangle budget');
  for I:=0 to M.VertexCount-1 do begin
    A:=M.VertexAt[I];Check(Abs(VecLength(A.Normal)-1)<0.001,'unit normals');
    Check(not IsNan(A.Position.Y),'finite geometry');
  end;
  for I:=0 to M.TriangleCount-1 do begin
    A:=M.VertexAt[M.IndexAt[I*3]];C:=M.VertexAt[M.IndexAt[I*3+1]];D:=M.VertexAt[M.IndexAt[I*3+2]];
    Cross:=VecCross(C.Position-A.Position,D.Position-A.Position);N:=A.Normal+C.Normal+D.Normal;
    Check(VecLength(Cross)>0.0000001,'degenerate triangle');Check(VecDot(Cross,N)>0,'outward winding');
  end;
end;
begin
  Folder:=IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  Checks:=0;
  Model:=TTileModel.Create;Tags:=TOSMTags.Create;
  try
    Model.TileId:=TGeoTileId.Make(0,True,4947,2560);
    Model.Origin:=TLatLon.Make(55.764,37.419);Model.Box:=TLatLonBox.Make(55.76,37.41,55.77,37.42);Model.GenHash:='lamp-test';
    for Style:=Low(Style) to High(Style) do begin
      M:=BuildStreetLamp(Style);L:=BuildStreetLamp(Style,True);B:=TMesh.Create;
      try
        Geometry(M);Geometry(L);Lo:=1e6;Hi:=-1e6;
        for I:=0 to M.VertexCount-1 do begin V:=M.VertexAt[I];Lo:=Min(Lo,V.Position.Y);Hi:=Max(Hi,V.Position.Y) end;
        Check(Lo>=-0.001,'ground foot');Check(Abs(Hi-StreetLampHeight(Style))<0.25,'height extent');
        TPOIBuilderExt.AppendInstance(B,M,Vector3(3,5,7),Pi/2,1.25);Geometry(B);
        WriteLn('style ',Ord(Style),' triangles ',M.TriangleCount+L.TriangleCount,' vertices ',M.VertexCount+L.VertexCount);
        Model.AddPOI(TPOIKindExt(Ord(pkxLampRoad)+Ord(Style)),Vector3(Ord(Style)*5,0,0),Pi/2,StreetLampHeight(Style)*1.1);
      finally B.Free;L.Free;M.Free end;
    end;
    Tags.Add('highway','street_lamp');Tags.Add('man_made','pole');
    Check(TPOIBuilderExt.ClassifyNode(Tags)=pkxLampRoad,'OSM lamp classification priority');
    Tags.Add('rezvivo:lamp_style','curved');Check(TPOIBuilderExt.ClassifyNode(Tags)=pkxLampCurved,'observed curved lamp');
    Tags.Clear;Tags.Add('man_made','utility_pole');Check(TPOIBuilderExt.ClassifyNode(Tags)=pkxPole,'utility poles unchanged');
    O:=TJSONObject(ParsePhotoJson('{"version":1,"boundary":[[37.419,55.764],[37.420,55.764],[37.420,55.765],[37.419,55.765]],"features":[{"id":"lamp","kind":"street_lamp","points":[[37.4195,55.7645]],"lamp_style":"curved","height_m":7.3,"heading_deg":90}]}'));
    try
      S:=CanonicalEnvironmentLayout(O,'street_furniture');Check(Pos('curved',S)>0,'lamp schema');
      TJSONObject(O.Arrays['features'][0]).Strings['lamp_style']:='invalid';Failed:=False;
      try S:=CanonicalEnvironmentLayout(O,'street_furniture') except Failed:=True end;Check(Failed,'invalid lamp style rejected');
      TJSONObject(O.Arrays['features'][0]).Strings['lamp_style']:='park';
      TJSONObject(O.Arrays['features'][0]).Floats['height_m']:=25;Failed:=False;
      try S:=CanonicalEnvironmentLayout(O,'street_furniture') except Failed:=True end;Check(Failed,'invalid lamp height rejected');
    finally O.Free end;
    TTileBinary.SaveFile(Folder+'lamp-roundtrip.o3dt',Model);
    Loaded:=TTileBinary.LoadFile(Folder+'lamp-roundtrip.o3dt');
    try
      Check(Loaded.POICount=Model.POICount,'binary lamp count');
      for I:=0 to Model.POICount-1 do Check((Loaded.POIs[I].Height=Model.POIs[I].Height) and (Loaded.POIs[I].Kind=Model.POIs[I].Kind),'binary lamp roundtrip');
    finally Loaded.Free end;
    Stream:=TMemoryStream.Create;
    try
      TTileX3D.SaveStream(Stream,Model);Stream.Position:=0;Loaded:=TTileX3D.LoadStream(Stream);
      try
        Check(Loaded.POICount=Model.POICount,'text lamp count');
        for I:=0 to Model.POICount-1 do Check(Abs(Loaded.POIs[I].Height-Model.POIs[I].Height)<0.002,'text lamp height');
      finally Loaded.Free end;
    finally Stream.Free end;
    if ParamCount>0 then begin
      Loaded:=TTileBinary.LoadFile(ParamStr(1),[tblPOIs]);
      try
        Check(Loaded.POICount>0,'legacy fixture has placements');
        for I:=0 to Loaded.POICount-1 do Check(Loaded.POIs[I].Height=0,'legacy optional heights');
      finally Loaded.Free end;
    end;
    WriteLn('PASS ',Checks,' lamp checks');
  finally Tags.Free;Model.Free end;
end.
