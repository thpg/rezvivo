program MeasuredAreaHeightTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,fpjson,jsonparser,Osm3dGeoMath,Osm3dOsmData,
  Osm3dMeasuredAreaHeight,Osm3dMeasuredRoadHeight,Osm3dGeomTerrain,
  Osm3dHeightmap,Osm3dGeomMesh;
procedure Check(B:Boolean;const S:string);
begin if not B then raise Exception.Create(S) end;
const TEXT='{"version":1,"datum":"dem_aligned","elevation_m":179.58,"feather_m":20,'+
  '"boundary":[[60,59],[60.002,59],[60.002,59.001],[60,59.001]]}';
var A:TMeasuredArea;D:TOSMDataset;W:TOSMWay;F:TMeasuredRoadHeight;P:TLatLon;
  J:TJSONData;S:string;I:Integer;H,H0,Weight:Single;HM:THeightmap;
  Proj:TLocalProjection;Sampler:TTerrainSampler;Mesh:TMesh;
procedure Reject(const Text:string);
var V:TJSONData;Bad:Boolean;
begin
  Bad:=False;V:=GetJSON(Text);
  try try CanonicalMeasuredArea(V) except on E:Exception do Bad:=True end finally V.Free end;
  Check(Bad,'invalid area accepted');
end;
begin
  A:=ReadMeasuredAreaText(TEXT);J:=GetJSON(TEXT);
  try S:=CanonicalMeasuredArea(J) finally J.Free end;
  J:=GetJSON(S);try Check(CanonicalMeasuredArea(J)=S,'canonical roundtrip') finally J.Free end;
  Reject(StringReplace(TEXT,'dem_aligned','raw_barometer',[]));
  Reject(StringReplace(TEXT,'"feather_m":20','"feather_m":0',[]));
  Reject(StringReplace(TEXT,'[60.002,59],[60.002,59.001]','[60.002,59.001],[60.002,59]',[]));
  Reject(StringReplace(TEXT,'[60,59.001]','[60,59]',[]));
  P:=TLatLon.Make(59.0005,60.001);Check(MeasuredAreaWeight(A,P)=1,'interior not flat');
  D:=TOSMDataset.Create;
  try
    W:=TOSMWay.Create(-1);W.Tags.Add(MEASURED_AREA_HEIGHT_TAG,S);D.AddWay(W);
    F:=TMeasuredRoadHeight.Create(D);
    try
      Check(not F.Empty,'area-only field considered empty');
      Check(F.TargetGeo(P,H,Weight) and (Abs(H-179.58)<0.001) and (Weight=1),'terrain flattener target');
      for I:=0 to 10 do begin
        P.Lon:=60+0.002*I/10;Check(Abs(F.ApplyGeo(P,160+I*3)-179.58)<0.001,'pad inherits DEM slope');
      end;
      P.Lon:=60.002+10/(111195.080233533*A.CosLat);H:=F.ApplyGeo(P,160);
      Check(Abs(H-169.79)<0.002,'half feather is not half correction');
      P.Lon:=60.003;Check(F.ApplyGeo(P,160)=160,'unrelated terrain changed');
      P.Lon:=60.002-0.0000001;H:=F.ApplyGeo(P,160);
      P.Lon:=60.002+0.0000001;Check(Abs(H-F.ApplyGeo(P,160))<0.001,'edge discontinuity');
      HM:=THeightmap.Create(32,32,TLatLonBox.Make(58.999,59.999,59.002,60.003));
      Proj:=TLocalProjection.Create(TLatLon.Make(59,60));
      try
        for I:=0 to 1023 do HM[I mod 32,I div 32]:=160+(I mod 32)*0.7;
        Sampler:=TTerrainSampler.Create(HM,Proj,10,13,1,nil,nil,nil,F);
        Mesh:=TTerrainBuilder.Build(HM,Proj,10,13,1,nil,nil,nil,nil,F);
        try
          P:=TLatLon.Make(59.0005,60.001);Check(Abs(Sampler.SampleAt(P)-179.58)<0.002,'sampler slope remains');
          Check(Abs(Sampler.SampleAtCubic(P)-179.58)<0.002,'cubic slope remains');
          Check(Abs(Sampler.SampleRawAt(P)-179.58)>1,'raw DEM overwritten');
          for I:=0 to Sampler.GridX*Sampler.GridZ-1 do
            Check(Abs(Mesh.VertexAt[I].Position.Y-Sampler.NodeHeight(I mod Sampler.GridX,I div Sampler.GridX))<0.002,'ground mesh mismatch');
        finally Mesh.Free;Sampler.Free end;
      finally Proj.Free;HM.Free end;
    finally F.Free end;
    D.AddNode(TOSMNode.Create(1,TLatLon.Make(58.999,60.001)));
    D.AddNode(TOSMNode.Create(2,TLatLon.Make(59.002,60.001)));
    W:=TOSMWay.Create(2);SetLength(W.NodeRefs,2);W.NodeRefs[0]:=1;W.NodeRefs[1]:=2;
    W.Tags.Add(MEASURED_ROAD_HEIGHT_TAG,'{"version":1,"datum":"dem_aligned","width_m":6,"feather_m":20,'+
      '"stations":[{"at_m":0,"elevation_m":175},{"at_m":333.585,"elevation_m":175}]}');D.AddWay(W);
    F:=TMeasuredRoadHeight.Create(D);
    try
      P:=TLatLon.Make(59.0005,60.001);Check(Abs(F.ApplyGeo(P,160)-179.58)<0.002,'road undoes level pad');
      P.Lat:=58.9995;Check(Abs(F.ApplyGeo(P,160)-175)<0.002,'pad changes distant road');
      H0:=175;
      for I:=0 to 100 do begin
        P.Lat:=59-20/111195.080233533+I*0.2/111195.080233533;H:=F.ApplyGeo(P,160);
        Check((H>=H0-0.0001) and (H-H0<0.08),'road/pad transition discontinuity');H0:=H;
      end;
    finally F.Free end;
  finally D.Free end;
  Writeln('PASS: validation, canonical, area-only, level pad, feather, exterior, road priority, continuity, raw DEM, sampler, baked lattice');
end.
