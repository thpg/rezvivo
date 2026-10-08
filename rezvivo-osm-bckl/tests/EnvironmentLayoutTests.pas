program EnvironmentLayoutTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,fpjson,CastleVectors,Osm3dPhotoSources,Osm3dEnvironmentLayout,
  Osm3dOsmData,Osm3dGeoMath,Osm3dGeomPOI,Osm3dGeomSurface,Osm3dGeomFences,
  Osm3dHeightmap,Osm3dGeomVegetation;
var D:TOSMDataset;N:TEnvironmentNodes;W:TEnvironmentWays;J,Q:TJSONObject;
  A:TJSONArray;S:string;P:TLocalProjection;H:THeightmap;POIs:TPOIInstanceArray;
  F:TForestBuildResult;I,Checks:Integer;Failed,OK:Boolean;Params:TFenceParams;
procedure Check(B:Boolean;const Msg:string);
begin if not B then raise Exception.Create(Msg);Inc(Checks) end;
function Layout(const Feature:string):TJSONObject;
begin Result:=TJSONObject(ParsePhotoJson('{"version":1,"boundary":[[60,59],[60.001,59],[60.001,59.001],[60,59.001]],"features":['+Feature+']}')) end;
begin
  D:=TOSMDataset.Create;N:=TEnvironmentNodes.Create(True);W:=TEnvironmentWays.Create(True);
  P:=TLocalProjection.Create(TLatLon.Make(59.0005,60.0005));
  H:=THeightmap.Create(8,8,TLatLonBox.Make(59,60,59.001,60.001));
  try
    J:=Layout('{"id":"seat","kind":"bench","points":[[60.0005,59.0005]],"heading_deg":90},'+
      '{"id":"bin","kind":"bin","points":[[60.0006,59.0005]]}');
    try
      S:=CanonicalEnvironmentLayout(J,'street_furniture');Q:=TJSONObject(ParsePhotoJson(S));
      try Check(S=CanonicalEnvironmentLayout(Q,'street_furniture'),'canonical roundtrip') finally Q.Free end;
      StageEnvironmentLayout(S,'local:test',D,N,W);Check((N.Count=2) and (W.Count=0),'two native nodes');
      N.OwnsObjects:=False;for I:=0 to N.Count-1 do D.AddNode(N[I]);N.Clear;N.OwnsObjects:=True;
      POIs:=TPOIBuilderExt.BuildAllInstances(D,H,P);Check(Length(POIs)=2,'native POIs');
      OK:=False;for I:=0 to High(POIs) do if POIs[I].Kind=pkxBench then OK:=Abs(POIs[I].Rotation+Pi/2)<0.001;
      Check(OK,'photo furniture heading');StageEnvironmentLayout(S,'local:test-again',D,N,W);Check(N.Count=0,'preserve existing furniture');
      Failed:=False;try S:=CanonicalEnvironmentLayout(J,'vegetation') except Failed:=True end;Check(Failed,'category guard');
      TJSONArray(TJSONObject(J.Arrays['features'][0]).Find('points')).Arrays[0].Floats[0]:=61;
      Failed:=False;try S:=CanonicalEnvironmentLayout(J,'street_furniture') except Failed:=True end;Check(Failed,'spatial scope guard');
    finally J.Free end;
    J:=TJSONObject(ParsePhotoJson('{"version":1,"boundary":[[60,59],[60.001,59],[60.001,59.001],[60.0007,59.001],[60.0007,59.0003],[60.0003,59.0003],[60.0003,59.001],[60,59.001]],'+
      '"features":[{"id":"outside-edge","kind":"fence","points":[[60.0001,59.0008],[60.0009,59.0008]]}]}'));
    try Failed:=False;try S:=CanonicalEnvironmentLayout(J,'fence') except Failed:=True end;Check(Failed,'concave boundary rejects escaping edge') finally J.Free end;
    J:=Layout('{"id":"fence","kind":"fence","points":[[60.0001,59.0002],[60.0004,59.0002],[60.0009,59.0002]],"height_m":1.4,"material":"metal","gates":[1]}');
    try S:=CanonicalEnvironmentLayout(J,'fence');StageEnvironmentLayout(S,'local:fence',D,N,W);
      Check(W.Count=1,'one native boundary');Check(N[1].Tags.HasKeyValue('barrier','gate'),'real gate opening node');
      Params:=TFenceBuilder.ParseFenceParams(W[0].Tags,W[0].Id,OK);Check(OK and (Abs(Params.Height-1.4)<0.001),'native fence height');
      Failed:=False;try StageEnvironmentLayout(S,'local:second-fence',D,N,W) except Failed:=True end;
      Check(Failed and (W.Count=1),'mapped boundary never receives a second parallel copy');
    finally J.Free;N.Clear;W.Clear end;
    J:=Layout('{"id":"trees","kind":"forest","points":[[60.0001,59.0003],[60.0009,59.0003],[60.0009,59.0009],[60.0001,59.0009]],"spacing_m":6,"genus":"betula"}');
    try S:=CanonicalEnvironmentLayout(J,'vegetation');StageEnvironmentLayout(S,'local:forest',D,N,W);
      Check(W[0].IsClosed,'closed native polygon');
      N.OwnsObjects:=False;W.OwnsObjects:=False;
      for I:=0 to N.Count-1 do D.AddNode(N[I]);for I:=0 to W.Count-1 do D.AddWay(W[I]);
      N.Clear;W.Clear;N.OwnsObjects:=True;W.OwnsObjects:=True;D.HasLocalPhotoVegetation:=True;
      F:=TForestInstanceBuilder.BuildAllDefaults(D,H,P);Check(Length(F.Trees)>20,'native density scatter, not excluded by own mask');
    finally J.Free end;
    J:=Layout('{"id":"shed","kind":"building","height_m":4,"points":[[60.0001,59.0001],[60.0003,59.0001],[60.0003,59.00025],[60.0001,59.00025]]}');
    try
      S:=CanonicalEnvironmentLayout(J,'building');StageEnvironmentLayout(S,'local:shed',D,N,W);
      Check(W.Count=1,'new measured footprint staged');
      Failed:=False;try StageEnvironmentLayout(S,'local:overlap',D,N,W) except Failed:=True end;
      Check(Failed,'duplicate local footprint rejected before publication');
    finally J.Free;W.Clear;N.Clear end;
    J:=Layout('{"id":"concave","kind":"building","height_m":4,"points":[[60.0001,59.0001],[60.0009,59.0001],[60.0009,59.0009],[60.0007,59.0009],[60.0007,59.0003],[60.0003,59.0003],[60.0003,59.0009],[60.0001,59.0009]]}');
    try
      S:=CanonicalEnvironmentLayout(J,'building');StageEnvironmentLayout(S,'local:concave',D,N,W);
      Failed:=False;try StageEnvironmentLayout(S,'local:concave-duplicate',D,N,W) except Failed:=True end;
      Check(Failed,'coincident concave footprint with centroid outside rejected');
    finally J.Free;W.Clear;N.Clear end;
    WriteLn('PASS ',Checks,' environment layout checks');
  finally H.Free;P.Free;W.Free;N.Free;D.Free end;
end.
