program MeasuredRoadHeightProbe;
{$mode objfpc}{$H+}
uses Classes,SysUtils,Math,fpjson,jsonparser,Osm3dCache,Osm3dCacheHTTPFetcher,
  Osm3dHeightmap,Osm3dGeoMath,Osm3dOsmData,Osm3dMeasuredRoadHeight,
  Osm3dGeomTerrain,Osm3dGeomMesh;
procedure Check(B:Boolean;const S:string);
begin if not B then raise Exception.Create(S) end;
procedure UnitTests;
var D:TOSMDataset;W:TOSMWay;F:TMeasuredRoadHeight;J:TJSONData;
  P:TLatLon;I:Integer;H,H2:Single;Profile:string;HM:THeightmap;
  Sampler:TTerrainSampler;Proj:TLocalProjection;Mesh:TMesh;Banks,Canonical:string;
  procedure Reject(const S:string);
  var V:TJSONData;Rejected:Boolean;
  begin
    V:=GetJSON(S);Rejected:=False;
    try try CanonicalMeasuredRoadHeight(V) except on E:Exception do Rejected:=True end
    finally V.Free end;
    Check(Rejected,'invalid profile accepted');
  end;
begin
  Reject('{"version":1,"datum":"raw_barometer","width_m":7,"feather_m":30,"stations":[{"at_m":0,"elevation_m":100},{"at_m":10,"elevation_m":101}]}');
  Reject('{"version":1,"datum":"dem_aligned","width_m":7,"feather_m":30,"stations":[{"at_m":10,"elevation_m":100},{"at_m":5,"elevation_m":101}]}');
  Reject('{"version":1,"datum":"dem_aligned","width_m":7,"feather_m":30,"stations":[{"at_m":0,"elevation_m":100},{"at_m":10,"elevation_m":120}]}');
  D:=TOSMDataset.Create;
  try
    P:=TLatLon.Make(55.76,37.42);D.AddNode(TOSMNode.Create(1,P));
    P.Lat+=0.001;D.AddNode(TOSMNode.Create(2,P));
    W:=TOSMWay.Create(1);SetLength(W.NodeRefs,2);W.NodeRefs[0]:=1;W.NodeRefs[1]:=2;D.AddWay(W);
    Profile:='{"version":1,"datum":"dem_aligned","width_m":7,"feather_m":30,"stations":[{"at_m":0,"elevation_m":100},{"at_m":111.195,"elevation_m":110}]}';
    J:=GetJSON(Profile);try Profile:=CanonicalMeasuredRoadHeight(J) finally J.Free end;
    Check(Abs(MeasuredRoadHeightRadius(Profile)-33.5)<0.001,'profile dependency radius differs from sampler');
    W.Tags.Add(MEASURED_ROAD_HEIGHT_TAG,Profile);F:=TMeasuredRoadHeight.Create(D);
    try
      Check(not F.Empty,'field empty');P:=TLatLon.Make(55.7605,37.42);
      Check(Abs(F.ApplyGeo(P,80)-105)<0.001,'linear grade interpolation');
      P.Lon+=3/(111195.080233533*Cos(P.Lat*Pi/180));Check(Abs(F.ApplyGeo(P,80)-105)<0.001,'road not level across its width');
      P.Lon:=37.42+18.5/(111195.080233533*Cos(P.Lat*Pi/180));H:=F.ApplyGeo(P,80);
      Check(Abs(H-92.5)<0.002,'feather or double application');
      P.Lon:=37.421;Check(F.ApplyGeo(P,80)=80,'unrelated ground changed');
      HM:=THeightmap.Create(64,64,TLatLonBox.Make(55.759,37.419,55.762,37.421));
      Proj:=TLocalProjection.Create(TLatLon.Make(55.76,37.42));
      try
        for I:=0 to 4095 do HM[I mod 64,I div 64]:=80;
        Sampler:=TTerrainSampler.Create(HM,Proj,10,13,1,nil,nil,nil,F);
        Mesh:=TTerrainBuilder.Build(HM,Proj,10,13,1,nil,nil,nil,nil,F);
        try
          P:=TLatLon.Make(55.7605,37.42);
          Check(Abs(Sampler.SampleAt(P)-105)<0.002,'sampler ignored authored height');
          Check(Abs(Sampler.SampleAtCubic(P)-105)<0.002,'cubic sampler ignored authored height');
          Check(Abs(Sampler.SampleRawAt(P)-80)<0.002,'raw DEM changed');
          for I:=0 to Sampler.GridX*Sampler.GridZ-1 do begin
            P:=Sampler.NodeLatLon(I mod Sampler.GridX,I div Sampler.GridX);
            Check(Abs(Sampler.NodeHeight(I mod Sampler.GridX,I div Sampler.GridX)-F.ApplyGeo(P,80))<0.002,'lattice mismatch');
            Check(Abs(Mesh.VertexAt[I].Position.Y-Sampler.NodeHeight(I mod Sampler.GridX,I div Sampler.GridX))<0.002,'mesh and sampler disagree');
          end;
        finally Mesh.Free;Sampler.Free end;
      finally Proj.Free;HM.Free end;
    finally F.Free end;
    Banks:='{"version":2,"datum":"dem_aligned","width_m":7,"feather_m":20,'+
      '"stations":[{"at_m":0,"elevation_m":100},{"at_m":111.195,"elevation_m":110}],'+
      '"terrain_sections":[{"at_m":0,"points":[[-8,-3],[-3.5,0],[3.5,0],[10,2]]},'+
      '{"at_m":111.195,"points":[[-8,-5],[-3.5,0],[3.5,0],[10,4]]}]}';
    J:=GetJSON(Banks);try Canonical:=CanonicalMeasuredRoadHeight(J) finally J.Free end;
    Check(Abs(MeasuredRoadHeightRadius(Canonical)-30)<0.001,'bank dependency radius differs from sampler');
    J:=GetJSON(Canonical);try Check(CanonicalMeasuredRoadHeight(J)=Canonical,'cross-section round trip') finally J.Free end;
    Reject(StringReplace(Banks,'[3.5,0]','[3.5,1]',[rfReplaceAll]));
    Reject(StringReplace(Banks,'[10,2]','[10,30]',[rfReplaceAll]));
    Reject(StringReplace(Banks,'"version":2','"version":1',[]));
    W.Tags.Add(MEASURED_ROAD_HEIGHT_TAG,Canonical);F:=TMeasuredRoadHeight.Create(D);
    try
      P:=TLatLon.Make(55.7605,37.42);
      Check(Abs(F.ApplyGeo(P,80)-105)<0.002,'bank deformed road core');
      P.Lon:=37.42-10/(111195.080233533*Cos(P.Lat*Pi/180));
      Check(Abs(F.ApplyGeo(P,80)-108)<0.003,'left uphill cut or longitudinal interpolation');
      P.Lon:=37.42+8/(111195.080233533*Cos(P.Lat*Pi/180));
      Check(Abs(F.ApplyGeo(P,80)-101)<0.003,'right downhill embankment');
      P.Lon:=37.42+18/(111195.080233533*Cos(P.Lat*Pi/180));
      Check(Abs(F.ApplyGeo(P,80)-90.5)<0.004,'bank outer blend');
      P.Lon:=37.42+75/(111195.080233533*Cos(P.Lat*Pi/180));
      Check(F.ApplyGeo(P,80)=80,'bank escaped local corridor');
    finally F.Free end;
    W.Tags.Add(MEASURED_ROAD_HEIGHT_TAG,'');F:=TMeasuredRoadHeight.Create(D);
    try Check(F.Empty,'disabled field');Check(F.ApplyGeo(P,123)=123,'disabled height') finally F.Free end;
    W.Tags.Add(MEASURED_ROAD_HEIGHT_TAG,Profile);
    P:=TLatLon.Make(55.76,37.42+30/(111195.080233533*Cos(55.7605*Pi/180)));
    D.AddNode(TOSMNode.Create(3,P));P.Lat+=0.001;D.AddNode(TOSMNode.Create(4,P));
    W:=TOSMWay.Create(2);SetLength(W.NodeRefs,2);W.NodeRefs[0]:=3;W.NodeRefs[1]:=4;
    W.Tags.Add(MEASURED_ROAD_HEIGHT_TAG,'{"version":1,"datum":"dem_aligned","width_m":7,"feather_m":30,"stations":[{"at_m":0,"elevation_m":120},{"at_m":111.195,"elevation_m":130}]}');D.AddWay(W);
    F:=TMeasuredRoadHeight.Create(D);
    try
      P:=TLatLon.Make(55.7605,37.42+14.999/(111195.080233533*Cos(55.7605*Pi/180)));H:=F.ApplyGeo(P,80);
      P.Lon:=37.42+15.001/(111195.080233533*Cos(55.7605*Pi/180));H2:=F.ApplyGeo(P,80);
      Check(Abs(H-H2)<0.02,'switchback bisector has a height discontinuity');
    finally F.Free end;
    { Asymmetric sections on one of two neighboring legs must not change the
      outer DEM blend discontinuously when the nearest segment switches. }
    W.Tags.Add(MEASURED_ROAD_HEIGHT_TAG,Canonical);F:=TMeasuredRoadHeight.Create(D);
    try
      P:=TLatLon.Make(55.7605,37.42+14.999/(111195.080233533*Cos(55.7605*Pi/180)));H:=F.ApplyGeo(P,80);
      P.Lon:=37.42+15.001/(111195.080233533*Cos(55.7605*Pi/180));H2:=F.ApplyGeo(P,80);
      Check(Abs(H-H2)<0.02,'asymmetric bank coverage jumps at bisector');
    finally F.Free end;
  finally D.Free end;
  Writeln('{"passed":true,"tests":"grade,width,feather,outside,sampler,cubic,raw,lattice,disabled,bank_left,bank_right,bank_core,bank_blend,bank_validation,bank_roundtrip"}');
end;
var Input:TStringList;Req,Reply:TJSONObject;Points,Heights:TJSONArray;
  Cache:TFileSystemCache;Http:THTTPFetcherWithCache;Fetcher:TTerrariumFetcher;
  I:Integer;H:Single;P:TLatLon;
begin
  if ParamCount=0 then begin UnitTests;Halt end;
  Input:=TStringList.Create;
  try Input.LoadFromFile(ParamStr(1));Req:=TJSONObject(GetJSON(Input.Text)) finally Input.Free end;
  Cache:=TFileSystemCache.Create(ParamStr(2));Http:=THTTPFetcherWithCache.Create(Cache);
  Fetcher:=TTerrariumFetcher.Create(Http);Reply:=TJSONObject.Create;Heights:=TJSONArray.Create;Reply.Add('heights',Heights);
  try
    Points:=TJSONArray(Req.Find('points'));
    for I:=0 to Points.Count-1 do begin
      P:=TLatLon.Make(Points[I].Items[1].AsFloat,Points[I].Items[0].AsFloat);
      if not Fetcher.TryHeightAtZoom(P,Req.Get('zoom',13),H) then raise Exception.Create('DEM unavailable');
      Heights.Add(H);
    end;
    Writeln(Reply.AsJSON);
  finally Reply.Free;Fetcher.Free;Http.Free;Cache.Free;Req.Free end;
end.
