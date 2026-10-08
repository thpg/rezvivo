program RoadFrameTests;
{$mode objfpc}{$H+}
uses SysUtils, Math, CastleVectors, GamePhysicsCommon,
  Osm3dGeoMath, Osm3dGeoTileGrid, Osm3dGeoTileBlock, Osm3dTileX3D,
  Osm3dBuildingObstacleIndex;

procedure Near(A,B,E:Double;const Msg:string);
begin
  if Abs(A-B)>E then raise Exception.CreateFmt('%s: %.6f <> %.6f',[Msg,A,B]);
end;

procedure TestFrame(FrameLat,TileLat,ManualLat:Double);
var Grid:TGeoTileGrid; Id:TGeoTileId; Center,Geo,FrameOrigin:TLatLon;
  Frame,Bake:TLocalProjection; Kx,BakeLat,ScaleLat:Double;
  P,Expected,Offset,D,Normal,Edge:TVector3; S,W:TTileRoadSeg;
  Obs,World:TBuildingObstacleArray;
begin
  FrameOrigin:=TLatLon.Make(FrameLat,60.021878);
  ScaleLat:=WorldScaleLatBand(FrameLat);
  if ManualLat<>0 then ScaleLat:=ManualLat;
  Grid:=TGeoTileGrid.Create(13,256,ScaleLat);
  Frame:=TLocalProjection.Create(FrameOrigin,ScaleLat);
  Bake:=nil;
  try
    Id:=Grid.TileAt(TLatLon.Make(TileLat,60.03));
    Center:=Grid.TileCenter(Id);
    BakeLat:=WorldScaleLatBand(BlockHaloBox(BlockOf(Id),Grid,0).Center.Lat);
    if ManualLat<>0 then BakeLat:=ManualLat;
    Bake:=TLocalProjection.Create(Center,BakeLat);
    Offset:=Frame.Project(Center);
    Kx:=TileFrameScaleX(Id,Grid,ScaleLat,ManualLat);
    Geo:=TLatLon.Make(Center.Lat+0.002,Center.Lon+0.018);
    P:=Bake.Project(Geo); Expected:=Frame.Project(Geo);
    S:=Default(TTileRoadSeg);S.X0:=P.X;S.Z0:=P.Z;
    S.X1:=P.X+25;S.Z1:=P.Z+100;S.Width:=8;S.WayId:=308175898;
    S.Surface.WidthStart:=6;S.Surface.WidthEnd:=8;
    W:=RoadSegmentToFrame(S,Offset,Kx);
    Near(W.X0,Expected.X,0.002,'road X matches geographic render frame');
    Near(W.Z0,Expected.Z,0.002,'road Z matches geographic render frame');
    D:=Vector3(W.X1-W.X0,0,W.Z1-W.Z0).Normalize;
    Normal:=Vector3(-100,0,25).Normalize;
    Edge:=Vector3(Normal.X*Kx,0,Normal.Z)*S.Width;
    Near(Abs(Edge.X*D.Z-Edge.Z*D.X),W.Width,0.001,'width fits transformed ribbon');
    Near(W.Surface.WidthStart/W.Surface.WidthEnd,0.75,1e-6,'taper ratio survives frame change');
    Near(W.Surface.WidthEnd,W.Width,0.001,'endpoint width uses the same transformed metric');
    SetLength(Obs,1);SetLength(Obs[0].Footprint,4);
    Obs[0].Footprint[0]:=P;Obs[0].Footprint[1]:=P+Vector3(10,0,0);
    Obs[0].Footprint[2]:=P+Vector3(10,0,10);Obs[0].Footprint[3]:=P+Vector3(0,0,10);
    RebuildObstacleAABB(Obs[0]);
    World:=OffsetObstaclesXZ(Obs,Offset.X,Offset.Z,Kx);
    Near(World[0].MinX,Expected.X,0.002,'obstacle aligned with road');
    Near(World[0].MaxX-World[0].MinX,10*Kx,0.002,'obstacle bounds scaled');
    Near(Obs[0].Footprint[0].X,P.X,0,'source footprint unchanged');
    if (ManualLat<>0) or (ScaleLat=BakeLat) then Near(Kx,1,1e-12,'same metric');
    Writeln('PASS tile frame lat=',FrameLat:0:5,' tile=',TileLat:0:5,' scale=',Kx:0:9);
  finally Bake.Free;Frame.Free;Grid.Free end;
end;

procedure TestLanes;
var M:TLaneManager; H,I,J:Integer; Width,Offset:Single;
begin
  for J:=0 to 2 do begin
    M:=TLaneManager.Create;
    try
      if J>0 then M.SetRoad(8*Power(4,J-1),50);
      H:=M.RegisterRider(nil);
      for I:=0 to 800 do begin
        Width:=I*0.02;
        Offset:=M.GetSmoothOffset(H,Width);
        if Abs(Offset)>Max(0,Width*0.5-0.4)+0.0001 then
          raise Exception.CreateFmt('outside road: count=%d width=%.2f offset=%.2f',[M.LaneCount,Width,Offset]);
        if Width<=5 then Near(Offset,0,0,'single file');
        Near(M.GetSmoothOffset(-1,Width),Offset,0.0001,'fallback respects local width');
      end;
      M.SetWidthProfile([0,100,200],[8,0,8]);M.SetPathLength(200);
      M.SetRiderPos(H,100);Near(M.GetSmoothOffset(H),0,0,'updated route length and width profile');
      M.SetRiderPos(H,200);Near(M.GetSmoothOffset(H),M.GetSmoothOffset(H,8),0.0001,'loop wrap');
    finally M.Free end;
  end;
  Writeln('PASS lanes: 2403 local widths, edge clearance, single file, refreshed loop');
end;

begin
  TestFrame(59.842336,59.944007,0);
  TestFrame(59.944007,59.842336,0);
  TestFrame(59.842336,59.842336,0);
  TestFrame(0,0,0);
  TestFrame(59.842336,59.944007,59.9);
  TestLanes;
end.
