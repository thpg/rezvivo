program BuildingPartSelectionTests;
{$mode objfpc}{$H+}
uses SysUtils,Osm3dGeoMath,Osm3dOsmData,Osm3dBuildingParts,
  Osm3dGeomBuildings,Osm3dHeightmap;
var D:TOSMDataset;S:TBuildingPartSelection;Checks,I:Integer;
  P:TLocalProjection;HM:THeightmap;M:TBuildingMeshes;R:TOSMRelation;
procedure Check(B:Boolean;const LabelText:string);
begin if not B then raise Exception.Create(LabelText);Inc(Checks) end;
procedure Node(Id,X,Y:Integer);
begin D.AddNode(TOSMNode.Create(Id,TLatLon.Make(59.76+Y*0.00001,60.19+X*0.00001))) end;
procedure Way(Id:Integer;const Refs:array of Int64;Part,Building:Boolean);
var W:TOSMWay;J:Integer;
begin
  W:=TOSMWay.Create(Id);SetLength(W.NodeRefs,Length(Refs));
  for J:=0 to High(Refs) do W.NodeRefs[J]:=Refs[J];
  if Building then W.Tags.Add('building','yes');
  if Part then W.Tags.Add('building:part','yes');
  W.Tags.Add('height',IntToStr(6+Id mod 3));W.Tags.Add('roof:shape','flat');D.AddWay(W);
end;
procedure Reset;
begin
  D.Free;D:=TOSMDataset.Create;
  Node(1,0,0);Node(2,10,0);Node(3,20,0);Node(4,20,10);Node(5,10,10);Node(6,0,10);
  Way(100,[1,2,3,4,5,6,1],False,True);
end;
procedure Selection;
begin S.Free;S:=TBuildingPartSelection.Create(D) end;
begin
  D:=nil;S:=nil;Checks:=0;
  try
    Reset;Selection;Check(not S.Hidden('way',100),'ordinary building retained');
    Way(101,[1,2,5,6,1],True,False);Selection;
    Check(not S.Hidden('way',100) and not S.PartVisible('way',101),'partial coverage retains parent');
    D.FindWay(101).Tags.Add('building','yes');Selection;
    Check(S.Hidden('way',101),'mixed building/part tags cannot bypass exclusion');
    D.FindWay(101).Tags.Add('rezvivo:photo_building','1');
    try S.ValidatePhotoParts(D);Check(False,'incomplete photo must reject') except on E:Exception do Check(Pos('complete, non-overlapping',E.Message)>0,'explicit incomplete-part reason') end;
    Way(102,[2,3,4,5,2],True,False);Selection;
    Check(S.Hidden('way',100) and S.PartVisible('way',101) and S.PartVisible('way',102),'complete partition replaces parent');
    S.ValidatePhotoParts(D);Inc(Checks);
    P:=TLocalProjection.Create(TLatLon.Make(59.76,60.19));HM:=THeightmap.Create(4,4,TLatLonBox.Make(59.75,60.18,59.77,60.2));
    try
      M:=TBuildingBuilderExt.BuildAll(D,HM,P);
      try Check(Length(M.TileAnchors)=2,'native render emits two parts, no parent')
      finally for I:=Low(M.Walls) to High(M.Walls) do begin M.Walls[I].Free;M.Roofs[I].Free end end;
    finally HM.Free;P.Free end;
    Way(103,[1,2,5,6,1],True,False);Selection;
    Check(not S.Hidden('way',100) and not S.PartVisible('way',101),'duplicate overlapping parts do not erase parent');
    Reset;Way(101,[1,2,5,6,1],True,False);Way(102,[2,3,4,5,2],True,False);
    D.Nodes.Remove(4);Selection;Check(not S.Hidden('way',100),'missing node retains parent');
    Reset;D.Ways.Remove(100);Way(101,[1,2,5,6,1],True,False);Selection;
    Check(S.PartVisible('way',101),'standalone complete part can render');
    Reset;D.Ways.Remove(100);Way(10,[1,2,3,4],False,False);Way(11,[4,5,6,1],False,False);
    R:=TOSMRelation.Create(100);R.Tags.Add('type','multipolygon');R.Tags.Add('building','yes');SetLength(R.Members,2);
    R.Members[0].Kind:=omkWay;R.Members[0].Ref:=10;R.Members[0].Role:='outer';
    R.Members[1].Kind:=omkWay;R.Members[1].Ref:=11;R.Members[1].Role:='outer';D.AddRelation(R);
    Way(101,[1,2,5,6,1],True,False);Way(102,[2,3,4,5,2],True,False);Selection;
    Check(S.Hidden('relation',100),'stitched multipolygon parent partitions correctly');
    { An unrelated part in a courtyard does not fill or replace its envelope. }
    Node(7,8,3);Node(8,12,3);Node(9,12,7);Node(10,8,7);Way(12,[7,8,9,10,7],False,False);
    SetLength(R.Members,3);R.Members[2].Kind:=omkWay;R.Members[2].Ref:=12;R.Members[2].Role:='inner';
    D.Ways.Remove(101);D.Ways.Remove(102);Node(11,9,4);Node(12,11,4);Node(13,11,6);Node(14,9,6);
    Way(103,[11,12,13,14,11],True,False);Selection;
    Check(not S.Hidden('relation',100) and S.PartVisible('way',103),'courtyard survives, separate inner object remains');
    WriteLn('PASS ',Checks,' building partition checks');
  finally S.Free;D.Free end;
end.
