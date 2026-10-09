program TileAllocationTests;
{$mode objfpc}{$H+}
uses Osm3dOSHeap, SysUtils, Math, CastleVectors, Osm3dGeomMesh,
  Osm3dGroundComposite, Osm3dBuildingFacade, Osm3dWaterLevel,
  Osm3dHeightmap, Osm3dGeoMath, Osm3dGeoTileGrid, Osm3dOsmData,
  Osm3dRoadCurbs, Osm3dTileX3D;

var OriginalMM, TrackingMM:TMemoryManager;
  Tracking:Boolean;
  LargeReallocations:Integer;
  RequestedBytes:QWord;

function CountRealloc(var P:Pointer; Size:PtrUInt):Pointer;
begin
  if Tracking and (Size>=32768) then begin
    Inc(LargeReallocations);Inc(RequestedBytes,Size);
  end;
  Result:=OriginalMM.ReAllocMem(P,Size);
end;

procedure Check(Condition:Boolean;const Msg:string);
begin if not Condition then raise Exception.Create(Msg) end;
procedure StartTracking;
begin LargeReallocations:=0;RequestedBytes:=0;Tracking:=True end;
procedure FinishTracking(const Name:string);
begin
  Tracking:=False;
  WriteLn(Name,': large_reallocations=',LargeReallocations,
    ' requested_mib=',RequestedBytes/1048576:0:3);
  Check(LargeReallocations<128,Name+' grows large buffers per object');
  Check(RequestedBytes<64*1024*1024,Name+' repeatedly copies a large buffer');
end;

procedure AddWall(M:TGroundCompositeMesh;Id:Int64;X:Single);
var V:TMeshVertex;I,B:Integer;
begin
  B:=M.VertexCount;V:=Default(TMeshVertex);
  V.Normal:=Vector3(0,0,1);V.OsmId:=Id;
  for I:=0 to 3 do begin
    V.Position:=Vector3(X,0,0);V.UV:=Vector2(0,0);
    if I in [1,2] then begin V.Position.X+=8;V.UV.X:=2 end;
    if I>=2 then begin V.Position.Y:=9;V.UV.Y:=3 end;
    M.AppendVertex(V,0);
  end;
  M.AppendTriangle(B,B+1,B+2,91);M.AppendTriangle(B,B+2,B+3,91);
end;

procedure TestComposite(Reserve:Boolean);
var Part,Whole:TGroundCompositeMesh;I:Integer;
begin
  Part:=TGroundCompositeMesh.Create('one wall');
  Whole:=TGroundCompositeMesh.Create('many walls');
  try
    AddWall(Part,42,0);Part.TrimArrays;
    if Reserve then Whole.ReserveForRawMerge(8192,4096,2048*Part.Pool.Count);
    StartTracking;
    for I:=0 to 2047 do Whole.AppendRawComposite(Part);
    FinishTracking('composite concat reserve='+BoolToStr(Reserve,True));Whole.TrimArrays;
    Check((Whole.VertexCount=8192) and (Whole.TriangleCount=4096),'concat counts');
    for I:=0 to 2047 do begin
      Check(Whole.Indices[I*6+5]=Cardinal(I*4+3),'concat index offset');
      Check(Whole.OsmIdOf(I*4)=42,'concat OSM identity');
      Check(Whole.PositionOf(I*4+2).Y=9,'concat pool offset');
      Check(Whole.TriTileKeyOf(I*2+1)=91,'concat tile identity');
    end;
  finally Whole.Free;Part.Free end;
end;

procedure TestFacades;
var M:TGroundCompositeMesh;D:TBuildingFacadeData;I:Integer;
begin
  M:=TGroundCompositeMesh.Create('many houses',0.999);D:=nil;
  try
    for I:=0 to 2047 do AddWall(M,1000+I,I*12);
    M.TrimArrays;StartTracking;
    D:=TBuildingFacadeData.Create(M,False);
    FinishTracking('facade preparation');
    Check(D.HouseCount=2048,'all houses retained');
    Check(Length(D.Frames)=2048,'all facade frames retained, no spare capacity');
    Check(Length(D.Info)=M.VertexCount*4,'facade vertex metadata length');
    for I:=0 to High(D.Frames) do begin
      Check(D.Frames[I].House=I,'facade ownership');
      Check(D.Frames[I].Rectangular,'facade bounds');
    end;
  finally D.Free;M.Free end;
end;

procedure TestUrbanCurbQuery;
const Scales:array[0..2]of Single=(0.5,1,2);
var M:TGroundCompositeMesh;Model:TTileModel;C:TCurbMesh;V:TMeshVertex;
  I,S,Shift,Far,Count:Integer;Origin:TVector3;
begin
  for S:=0 to 2 do for Shift:=0 to 1 do for Far:=0 to 1 do begin
    Origin:=Vector3(Shift*10000,0,-Shift*9000);
    M:=TGroundCompositeMesh.Create('urban curb');Model:=TTileModel.Create;
    try
      V:=Default(TMeshVertex);V.Normal:=Vector3(0,1,0);V.OsmId:=101;
      V.Position:=Origin+Vector3(-12,0,0);M.AppendVertex(V,24);
      V.Position:=Origin+Vector3(12,0,0);M.AppendVertex(V,24);
      V.Position:=Origin+Vector3(0,0,-4);M.AppendVertex(V,24);M.AppendTriangle(0,1,2);
      V.OsmId:=0;
      V.Position:=Origin+Vector3(-12,0,0);M.AppendVertex(V,0);
      V.Position:=Origin+Vector3(12,0,0);M.AppendVertex(V,0);
      V.Position:=Origin+Vector3(0,0,5);M.AppendVertex(V,0);M.AppendTriangle(4,3,5);
      SetLength(Model.BuildingObstacles,3);
      for I:=0 to 2 do with Model.BuildingObstacles[I] do begin
        MinX:=0;MaxX:=1;MinZ:=10;MaxZ:=12;
        if I=2 then begin
          MinX:=85/Scales[S];MaxX:=MinX+1;
          MinZ:=60+Far*200;MaxZ:=MinZ+2;
        end;
      end;
      C:=Default(TCurbMesh);
      Count:=AppendUrbanRoadCurbs(M,Model,Origin,Scales[S],C);
      Check((Count>0)=(Far=0),'urban curb metric and origin-independent proximity');
    finally Model.Free;M.Free end;
  end;
  WriteLn('PASS curb proximity: scaled/translated/remote buildings');
end;

procedure TestWaterArea(IsRiver:Boolean);
var Grid:TGeoTileGrid;HM:THeightmap;DS:TOSMDataset;Proj:TLocalProjection;
  W:TOSMWay;Level:TWaterLevelField;Box:TLatLonBox;Id:TGeoTileId;
  I,X,Z:Integer;Angle:Double;
begin
  Grid:=TGeoTileGrid.Create(15,256,55.75);
  Id:=Grid.TileAt(TLatLon.Make(55.75,37.6));Box:=Grid.TileBox(Id);
  Proj:=TLocalProjection.Create(Box.Center);HM:=THeightmap.Create(256,256,Box);
  DS:=TOSMDataset.Create;Level:=nil;
  try
    for Z:=0 to 255 do for X:=0 to 255 do HM[X,Z]:=20;
    W:=TOSMWay.Create(10000);W.Tags.Add('natural','water');
    if IsRiver then W.Tags.Add('water','river') else W.Tags.Add('water','lake');
    SetLength(W.NodeRefs,4097);
    for I:=0 to 4095 do begin
      Angle:=I*2*Pi/4096;W.NodeRefs[I]:=I+1;
      DS.AddNode(TOSMNode.Create(I+1,Proj.Unproject(200*Cos(Angle),100*Sin(Angle))));
    end;
    W.NodeRefs[4096]:=1;DS.AddWay(W);StartTracking;
    Level:=TWaterLevelField.Create(HM,DS,Proj,15,nil,False);
    FinishTracking('water polygon river='+BoolToStr(IsRiver,True));
    Check(not Level.Empty,'polygon water retained');
    Check(Abs(Level.Apply(0,0,80)-20)<0.001,'polygon level');
    Check(Abs(Level.Apply(150,0,80)-20)<0.001,'polygon interior');
    Check(Level.Apply(250,0,80)=80,'land beyond polygon shore');
  finally Level.Free;DS.Free;HM.Free;Proj.Free;Grid.Free end;
end;

procedure TestWater;
var Grid:TGeoTileGrid;HM:THeightmap;DS:TOSMDataset;Proj:TLocalProjection;
  W:TOSMWay;Level:TWaterLevelField;Box:TLatLonBox;Id:TGeoTileId;
  I,J,X,Z:Integer;NodeId:Int64;
begin
  Grid:=TGeoTileGrid.Create(15,256,55.75);
  Id:=Grid.TileAt(TLatLon.Make(55.75,37.6));Box:=Grid.TileBox(Id);
  Proj:=TLocalProjection.Create(Box.Center);HM:=THeightmap.Create(256,256,Box);
  DS:=TOSMDataset.Create;Level:=nil;
  try
    for Z:=0 to 255 do for X:=0 to 255 do HM[X,Z]:=20;
    { Thousands of real source spans in the same local field. Repeated
      crossings also exercise densely populated spatial-index buckets. }
    for I:=0 to 39 do begin
      W:=TOSMWay.Create(10000+I);W.Tags.Add('waterway','stream');
      SetLength(W.NodeRefs,65);
      for J:=0 to 64 do begin
        NodeId:=1+I*65+J;W.NodeRefs[J]:=NodeId;
        DS.AddNode(TOSMNode.Create(NodeId,Proj.Unproject(-200+J*6.25,-195+I*10)));
      end;
      DS.AddWay(W);
    end;
    StartTracking;
    Level:=TWaterLevelField.Create(HM,DS,Proj,15,nil,False);
    FinishTracking('water axes and grid');
    Check(not Level.Empty,'water retained');
    for I:=0 to 39 do
      Check(Abs(Level.Apply(0,-195+I*10,80)-20)<0.001,'stream level');
    Check(Level.Apply(260,0,80)=80,'water does not affect remote land');
    WriteLn(Level.Stats);
  finally Level.Free;DS.Free;HM.Free;Proj.Free;Grid.Free end;
end;

begin
  GetMemoryManager(OriginalMM);TrackingMM:=OriginalMM;
  TrackingMM.ReAllocMem:=@CountRealloc;SetMemoryManager(TrackingMM);
  try TestComposite(False);TestComposite(True);TestFacades;TestUrbanCurbQuery;
    TestWater;TestWaterArea(False);TestWaterArea(True);
    WriteLn('TILE_ALLOCATION_TESTS_OK');
  finally Tracking:=False;SetMemoryManager(OriginalMM) end;
end.
