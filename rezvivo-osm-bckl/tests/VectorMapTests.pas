program VectorMapTests;
{$mode objfpc}{$H+}
uses Classes, SysUtils, Math, Osm3dGeoMath, Osm3dOsmData, Osm3dVectorMap;
type TCancelledWorker=class(TThread)
  procedure Execute;override;
end;
procedure TCancelledWorker.Execute;
begin end;
procedure Check(B:Boolean;const What:string);
begin if not B then raise Exception.Create(What);end;
function Find(D:TMapVectorData;const Key:string):TMapVectorFeature;
var I:Integer;
begin
  for I:=0 to D.Features.Count-1 do begin
    Result:=TMapVectorFeature(D.Features[I]);if Result.Key=Key then Exit;
  end;
  Result:=nil;
end;
var Data:TOSMDataset;Full,Coarse,Stopped:TMapVectorData;Tile:TTileXY;
  R:TOSMRelation;W:TOSMWay;N:TOSMNode;F:TMapVectorFeature;
  I:Integer;A,B,C:TLatLon;Area:Double;Worker:TCancelledWorker;
procedure Node(Id:Int64;Lat,Lon:Double);
begin Data.AddNode(TOSMNode.Create(Id,TLatLon.Make(Lat,Lon)));end;
procedure Way(Id:Int64;const Nodes:array of Int64);
var J:Integer;
begin
  W:=TOSMWay.Create(Id);SetLength(W.NodeRefs,Length(Nodes));
  for J:=0 to High(Nodes)do W.NodeRefs[J]:=Nodes[J];Data.AddWay(W);
end;
begin
  Data:=TOSMDataset.Create;Full:=nil;Coarse:=nil;Stopped:=nil;Worker:=nil;
  try
    Node(1,55,37);Node(2,55,37.002);Node(3,55.002,37.002);Node(4,55.002,37);
    Node(5,55.0007,37.0007);Node(6,55.0007,37.0013);
    Node(7,55.0013,37.0013);Node(8,55.0013,37.0007);
    Way(100,[1,2,3,4,1]);W.Tags.Add('building','yes');
    Way(101,[5,6,7,8,5]);
    R:=TOSMRelation.Create(200);R.Tags.Add('type','multipolygon');R.Tags.Add('building','yes');
    SetLength(R.Members,2);
    R.Members[0].Kind:=omkWay;R.Members[0].Ref:=100;R.Members[0].Role:='outer';
    R.Members[1].Kind:=omkWay;R.Members[1].Ref:=101;R.Members[1].Role:='inner';
    Data.AddRelation(R);
    Way(300,[1,3]);W.Tags.Add('highway','primary');W.Tags.Add('bridge','yes');W.Tags.Add('name','Main Road');
    Way(301,[2,4]);W.Tags.Add('highway','service');
    Way(302,[1,9999]);W.Tags.Add('highway','primary');
    N:=Data.FindNode(1);N.Tags.Add('place','town');N.Tags.Add('name','Test Town');N.Tags.Add('population','50000');
    Tile:=TTileMath.LatLonToTile(TLatLon.Make(55,37),14);
    Full:=BuildMapVectors(Data,Tile);Coarse:=BuildMapVectors(Data,Tile,nil,13);
    F:=Find(Full,'r200:0');Check(F<>nil,'multipolygon not generated');
    Check(Find(Full,'w100')=nil,'relation member duplicated');
    Area:=0;I:=0;
    while I<Length(F.Triangles)do begin
      A:=F.Points[F.Triangles[I]];B:=F.Points[F.Triangles[I+1]];C:=F.Points[F.Triangles[I+2]];
      Area:=Area+Abs((B.Lon-A.Lon)*(C.Lat-A.Lat)-(B.Lat-A.Lat)*(C.Lon-A.Lon))/2;Inc(I,3);
    end;
    Check(Abs(Area-0.00000364)<1E-9,'courtyard hole was filled or triangulation lost area');
    F:=Find(Full,'l300');Check((F<>nil)and(F.Kind=mfPrimary)and(F.Layer=1),'bridge classification/layer');
    Check(Find(Full,'l302')=nil,'incomplete way should not generate a false connection');
    Check(Find(Coarse,'r200:0')=nil,'overview retains invisible buildings');
    Check(Find(Coarse,'l301')=nil,'overview retains service road geometry');
    Check(Find(Coarse,'l300')<>nil,'overview loses primary road');
    F:=Find(Coarse,'n1');Check((F<>nil)and(F.Population=50000)and(F.LabelPriority>100),'place priority/population');
    Worker:=TCancelledWorker.Create(True);Worker.Terminate;Worker.Start;Worker.WaitFor;
    Stopped:=BuildMapVectors(Data,Tile,Worker);Check(Stopped.Features.Count=0,'cancelled extraction continues');
    Check((Coarse.Bytes<Full.Bytes)and(Coarse.MaxZoom=13),'overview cache does not shrink');
    WriteLn('PASS: polygon holes, deduplication, road layers, label priorities, overview memory and cancellation');
  finally Worker.Free;Stopped.Free;Coarse.Free;Full.Free;Data.Free;end;
end.
