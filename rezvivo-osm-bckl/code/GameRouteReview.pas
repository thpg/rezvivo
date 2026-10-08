unit GameRouteReview;
{$mode objfpc}{$H+}{$codepage UTF8}{$modeswitch advancedrecords}
interface
uses Classes,SysUtils,SyncObjs,CastleVectors,Osm3dGeoMath,Osm3dMapUtils,
  Osm3dStudioSettings,Osm3dTileX3D;
type
  TRouteConcern=(rcUnmatched,rcLargeMove,rcWidth,rcSurface,rcHeight,rcBuilding);
  TRouteConcerns=set of TRouteConcern;
  TRouteReviewPoint=record
    Issues:TRouteConcerns;
    Distance,Move,Height:Double;
    HasHeight,Structure:Boolean;
  end;
  TRouteReviewPoints=array of TRouteReviewPoint;
  TRouteReview=record
    Done:Boolean;
    ErrorText:string;
    Original,Corrected,Ride:TRouteLatLonArray;
    Points:TRouteReviewPoints;
    Tiles,CheckedTiles,MissingTiles,ConcernPoints,StructurePoints:Integer;
    WidthMin,WidthMax,MaxMove:Double;
    Turnarounds:Boolean;
    function Caption:string;
  end;
  { Exact selected-way surface test on cached render triangles. Upward road
    faces only: no grass, roof, tunnel ceiling or unrelated stacked deck. }
  function ReviewRoadSurface(const R:TTileMeshRec;Way:Int64;
    X,Z:Single;out Y:Single):Boolean;
  procedure ReviewRouteShape(const Original,Corrected:TRouteLatLonArray;
    const Widths:TRouteWidthArray;const Ways:TRouteWayIdArray;
    out Review:TRouteReview);
  procedure ReviewHeightSteps(var Review:TRouteReview);
type
  TRouteReviewTask=class(TThread)
  private
    FLock:TCriticalSection;
    FResult:TRouteReview;
    FSettings:TStudioSettings;
    FOrigin:TLatLon;
    FCacheRoot,FGenHash:string;
    FOriginal,FCorrected,FRide:TRouteLatLonArray;
    FWidths:TRouteWidthArray;FWays:TRouteWayIdArray;
    FRegistered:Boolean;
    procedure RunReview;
  protected
    procedure Execute;override;
  public
    constructor Create(const Settings:TStudioSettings;const CacheRoot,GenHash:string;
      const Origin:TLatLon;const Original,Corrected,Ride:TRouteLatLonArray;
      const Widths:TRouteWidthArray;const Ways:TRouteWayIdArray);
    destructor Destroy;override;
    function Snapshot:TRouteReview;
    procedure Abandon;
  end;
implementation
uses Math,Generics.Collections,UiTranslations,Osm3dGeoTileGrid,Osm3dGeoTileBlock,
  Osm3dGeoTileCache,Osm3dGroundComposite,Osm3dSceneMaterials,Osm3dGeomMesh,
  Osm3dRouteBuildings,Osm3dBuildingObstacleIndex,Osm3dRoadSurface;
type TIntList=specialize TList<Integer>;
  TWayPoints=specialize TObjectDictionary<Int64,TIntList>;
var Tasks:TList;TasksLock:TCriticalSection;Idle:TEvent;
procedure UnregisterTask(Task:TRouteReviewTask);
begin
  if not Task.FRegistered then Exit;
  TasksLock.Enter;
  try Tasks.Remove(Task);Task.FRegistered:=False;if Tasks.Count=0 then Idle.SetEvent;
  finally TasksLock.Leave end;
end;
function TRouteReview.Caption:string;
var C:TRouteConcern;N,I:Integer;Text:string;
const Names:array[TRouteConcern]of string=(
  'No road match','Large route correction','Road width mismatch',
  'Selected road surface not confirmed','Abrupt surface elevation change',
  'Building intersection before detour');
begin
  if ErrorText<>''then Exit(UiText('Route check failed: ')+ErrorText);
  if not Done then Exit(Format(UiText('Checking prepared geometry: %d/%d tiles'),[CheckedTiles,Tiles]));
  Result:=Format(UiText('Checked %d/%d tiles; %d points need review.'),[CheckedTiles,Tiles,ConcernPoints]);
  Result:=Result+LineEnding+Format(UiText('Road width %.1f–%.1f m; maximum correction %.1f m.'),[WidthMin,WidthMax,MaxMove]);
  if Turnarounds then Result:=Result+LineEnding+UiText('Out and back: turnaround at both endpoints; no closing shortcut.');
  for C:=Low(TRouteConcern)to High(TRouteConcern)do begin
    N:=0;for I:=0 to High(Points)do if C in Points[I].Issues then Inc(N);
    if N=0 then Continue;
    Text:=UiText(Names[C])+': '+IntToStr(N);Result:=Result+LineEnding+Text;
  end;
  if StructurePoints>0 then Result:=Result+LineEnding+Format(UiText('Bridge/tunnel points checked: %d'),[StructurePoints]);
  Result:=Result+LineEnding+UiText('Geometry before FIT height correction. Warnings are for review, not an automatic route change.');
end;
procedure ReviewRouteShape(const Original,Corrected:TRouteLatLonArray;
  const Widths:TRouteWidthArray;const Ways:TRouteWayIdArray;out Review:TRouteReview);
var I,N:Integer;W:Double;
begin
  Review:=Default(TRouteReview);N:=Length(Original);
  if(N<2)or(Length(Corrected)<>N)or(Length(Widths)<>N)or(Length(Ways)<>N)then
    raise Exception.Create('Prepared route arrays have different lengths');
  Review.Original:=Copy(Original);Review.Corrected:=Copy(Corrected);
  Review.Turnarounds:=RouteNeedsTurnarounds(Corrected);
  SetLength(Review.Points,N);Review.WidthMin:=1E30;
  for I:=0 to N-1 do begin
    if I>0 then Review.Points[I].Distance:=Review.Points[I-1].Distance+Original[I-1].DistanceTo(Original[I]);
    Review.Points[I].Move:=Original[I].DistanceTo(Corrected[I]);
    Review.MaxMove:=Max(Review.MaxMove,Review.Points[I].Move);
    if Review.Points[I].Move>8 then Include(Review.Points[I].Issues,rcLargeMove);
    W:=Widths[I];
    if(Ways[I]=0)or(W<=0)then Include(Review.Points[I].Issues,rcUnmatched)
    else begin
      Review.WidthMin:=Min(Review.WidthMin,W);Review.WidthMax:=Max(Review.WidthMax,W);
      if(W<0.8)or(W>60)then Include(Review.Points[I].Issues,rcWidth);
    end;
  end;
  if Review.WidthMin=1E30 then Review.WidthMin:=0;
end;
procedure ReviewHeightSteps(var Review:TRouteReview);
var I:Integer;D,DY:Double;
begin
  for I:=1 to High(Review.Points)do begin
    if not(Review.Points[I-1].HasHeight and Review.Points[I].HasHeight)then Continue;
    D:=Review.Corrected[I-1].DistanceTo(Review.Corrected[I]);
    DY:=Abs(Review.Points[I].Height-Review.Points[I-1].Height);
    if(DY>2)and(DY>Max(0.5,D)*0.35)then Include(Review.Points[I].Issues,rcHeight);
  end;
  Review.ConcernPoints:=0;Review.StructurePoints:=0;
  for I:=0 to High(Review.Points)do begin
    if Review.Points[I].Issues<>[]then Inc(Review.ConcernPoints);
    if Review.Points[I].Structure then Inc(Review.StructurePoints);
  end;
end;
function RoadTriangle(const R:TTileMeshRec;A,B,C:Integer;Way:Int64):Boolean;
var V:TMeshVertexArray;M:Integer;
begin
  Result:=False;V:=R.Mesh.Vertices;
  if not(R.Material in[smkTerrain,smkGrass,smkSurface,smkSand,smkFarmland,smkForest,
    smkRoad,smkRoadMajor,smkRoadSecondary,smkRoadMinor,smkRoadService,
    smkRoadFootway,smkRoadCycleway,smkRoadRailway])then Exit;
  if(Way=0)or(V[A].OsmId<>Way)or(V[B].OsmId<>Way)or(V[C].OsmId<>Way)then Exit;
  if Length(R.MatIds)>0 then begin
    M:=R.MatIds[A];
    if not((M=GROUND_MAT_ROAD_SAND)or((M>=GROUND_MAT_ROAD_FIRST)and(M<GROUND_MAT_COUNT)))then Exit;
    if(R.MatIds[B]<>M)or(R.MatIds[C]<>M)then Exit;
  end else if not(R.Material in[smkRoad,smkRoadMajor,smkRoadSecondary,smkRoadMinor,
    smkRoadService,smkRoadFootway,smkRoadCycleway,smkRoadRailway])then Exit;
  Result:=True;
end;
function TriangleHeight(const A,B,C:TVector3;X,Z:Single;out Y:Single):Boolean;
var D,U,V,NY:Double;
begin
  Result:=False;
  NY:=(B.Z-A.Z)*(C.X-A.X)-(B.X-A.X)*(C.Z-A.Z);
  if NY<=1E-8 then Exit; { only the upward rideable face }
  D:=(B.Z-C.Z)*(A.X-C.X)+(C.X-B.X)*(A.Z-C.Z);
  U:=((B.Z-C.Z)*(X-C.X)+(C.X-B.X)*(Z-C.Z))/D;
  V:=((C.Z-A.Z)*(X-C.X)+(A.X-C.X)*(Z-C.Z))/D;
  if(U< -0.0001)or(V< -0.0001)or(U+V>1.0001)then Exit;
  Y:=U*A.Y+V*B.Y+(1-U-V)*C.Y;Result:=True;
end;
function ReviewRoadSurface(const R:TTileMeshRec;Way:Int64;X,Z:Single;out Y:Single):Boolean;
var I,A,B,C:Integer;V:TMeshVertexArray;Idx:TMeshIndexArray;H:Single;
begin
  Result:=False;Y:=0;if R.Mesh=nil then Exit;
  V:=R.Mesh.Vertices;Idx:=R.Mesh.Indices;
  for I:=0 to R.Mesh.TriangleCount-1 do begin
    A:=Idx[I*3];B:=Idx[I*3+1];C:=Idx[I*3+2];
    if RoadTriangle(R,A,B,C,Way)and TriangleHeight(V[A].Position,V[B].Position,V[C].Position,X,Z,H)then
    begin
      if Result and(Abs(H-Y)>2)then Exit(False); { ambiguous same-way stacked road }
      if not Result or(H<Y)then begin Y:=H;Result:=True end;
    end;
  end;
end;
constructor TRouteReviewTask.Create(const Settings:TStudioSettings;const CacheRoot,GenHash:string;
  const Origin:TLatLon;const Original,Corrected,Ride:TRouteLatLonArray;
  const Widths:TRouteWidthArray;const Ways:TRouteWayIdArray);
begin
  inherited Create(True);FLock:=TCriticalSection.Create;FSettings:=Settings;
  FOrigin:=Origin;FCacheRoot:=CacheRoot;FGenHash:=GenHash;
  FOriginal:=Copy(Original);FCorrected:=Copy(Corrected);FRide:=Copy(Ride);
  FWidths:=Copy(Widths);FWays:=Copy(Ways);
  TasksLock.Enter;try Tasks.Add(Self);FRegistered:=True;Idle.ResetEvent;finally TasksLock.Leave end;
  Start;
end;
destructor TRouteReviewTask.Destroy;
begin UnregisterTask(Self);FLock.Free;inherited end;
procedure TRouteReviewTask.Abandon;
var Complete:Boolean;
begin
  FLock.Enter;try Terminate;Complete:=FResult.Done;if not Complete then FreeOnTerminate:=True;
  finally FLock.Leave end;
  if Complete then Free;
end;
function TRouteReviewTask.Snapshot:TRouteReview;
begin FLock.Enter;try Result:=FResult;finally FLock.Leave end end;
procedure TRouteReviewTask.Execute;
begin
  try RunReview;
  except on E:Exception do begin FLock.Enter;try FResult.ErrorText:=E.Message;finally FLock.Leave end end;
  end;
  FLock.Enter;try FResult.Done:=True;finally FLock.Leave end;
  UnregisterTask(Self);
end;
procedure TRouteReviewTask.RunReview;
var Review:TRouteReview;Cache:TGeoTileCache;Proj:TLocalProjection;
  TilePoints:specialize TObjectDictionary<Int64,TIntList>;Pair:specialize TPair<Int64,TIntList>;
  Points:TIntList;ByWay:TWayPoints;Model:TTileModel;Tile:TGeoTileId;
  I,J,K,A,B,C,MI,PI,SI:Integer;R:TTileMeshRec;Verts:TMeshVertexArray;Idx:TMeshIndexArray;
  Local:array of TVector3;Center,P:TVector3;FrameLat,ScaleX,D,T,DX,DZ,Best:Double;
  H,BaseY,TopY:Single;Seg:TTileRoadSeg;Obstacles:TBuildingObstacleIndex;
begin
  ReviewRouteShape(FOriginal,FCorrected,FWidths,FWays,Review);Review.Ride:=FRide;
  FrameLat:=EffectiveWorldScaleLat(FSettings,FOrigin.Lat);
  Proj:=TLocalProjection.Create(FOrigin,FrameLat);
  Cache:=TGeoTileCache.Create(FCacheRoot,FGenHash,FSettings.HeightmapZoom,GEO_TILE_EDGE_PX,FrameLat);
  TilePoints:=specialize TObjectDictionary<Int64,TIntList>.Create([doOwnsValues]);
  try
    for I:=0 to High(FCorrected)do begin
      Tile:=Cache.Grid.TileAt(FCorrected[I]);
      if not TilePoints.TryGetValue(Tile.ToKey,Points)then begin Points:=TIntList.Create;TilePoints.Add(Tile.ToKey,Points)end;
      Points.Add(I);
    end;
    Review.Tiles:=TilePoints.Count;SetLength(Local,Length(FCorrected));
    for Pair in TilePoints do begin
      if Terminated then Exit;
      Points:=Pair.Value;Tile:=Cache.Grid.TileAt(FCorrected[Points[0]]);Model:=nil;
      if not Cache.TryLoad(Tile,Model)then begin
        Inc(Review.MissingTiles);
        for I in Points do Include(Review.Points[I].Issues,rcSurface);
      end else try
        Center:=Proj.Project(Model.Origin);ScaleX:=TileFrameScaleX(Tile,Cache.Grid,FrameLat,FSettings.WorldScaleLatDeg);
        ByWay:=TWayPoints.Create([doOwnsValues]);Obstacles:=TBuildingObstacleIndex.Create;
        try
          Obstacles.AddObstacles(Model.BuildingObstacles,Tile.ToKey);
          for I in Pair.Value do begin
            P:=Proj.Project(FCorrected[I]);P.X:=(P.X-Center.X)/ScaleX;P.Z:=P.Z-Center.Z;Local[I]:=P;
            if Obstacles.TryQuery(P.X,P.Z,BaseY,TopY)then Include(Review.Points[I].Issues,rcBuilding);
            if FWays[I]=0 then Continue;
            if not ByWay.TryGetValue(FWays[I],Points)then begin Points:=TIntList.Create;ByWay.Add(FWays[I],Points)end;
            Points.Add(I);Best:=1E30;
            for SI:=0 to Model.RoadSegCount-1 do begin
              Seg:=Model.RoadSegs[SI];if Seg.WayId<>FWays[I]then Continue;
              DX:=Seg.X1-Seg.X0;DZ:=Seg.Z1-Seg.Z0;
              T:=EnsureRange(((P.X-Seg.X0)*DX+(P.Z-Seg.Z0)*DZ)/Max(1E-10,DX*DX+DZ*DZ),0.0,1.0);
              D:=Sqr(P.X-Seg.X0-T*DX)+Sqr(P.Z-Seg.Z0-T*DZ);
              if D<Best then begin
                Best:=D;Review.Points[I].Structure:=Seg.IsBridge;
                { Reuse the rendered centerline transform, including latitude scale. }
                Seg:=RoadSegmentToFrame(Seg,Center,ScaleX);
                if Abs(RoadWidthAt(Seg.Surface,Seg.Width,T)-FWidths[I])>Max(0.5,FWidths[I]*0.15)then Include(Review.Points[I].Issues,rcWidth)
                else if(FWidths[I]>=0.8)and(FWidths[I]<=60)then Exclude(Review.Points[I].Issues,rcWidth);
              end;
            end;
          end;
          { Walk triangles once; only inspect route points assigned to that way.
            Unrelated materials never become substitute surfaces. }
          for MI:=0 to Model.MeshCount-1 do begin
            if Terminated then Exit;
            R:=Model.Meshes[MI];if R.Mesh=nil then Continue;
            Verts:=R.Mesh.Vertices;Idx:=R.Mesh.Indices;
            for J:=0 to R.Mesh.TriangleCount-1 do begin
              if(J and 8191=0)and Terminated then Exit;
              A:=Idx[J*3];B:=Idx[J*3+1];C:=Idx[J*3+2];
              if not ByWay.TryGetValue(Verts[A].OsmId,Points)then Continue;
              if not RoadTriangle(R,A,B,C,Verts[A].OsmId)then Continue;
              for K:=0 to Points.Count-1 do begin
                PI:=Points[K];P:=Local[PI];
                if TriangleHeight(Verts[A].Position,Verts[B].Position,Verts[C].Position,P.X,P.Z,H)then
                begin
                  if Review.Points[PI].HasHeight and(Abs(H-Review.Points[PI].Height)>2)then
                    Include(Review.Points[PI].Issues,rcSurface);
                  if not Review.Points[PI].HasHeight or(H<Review.Points[PI].Height)then begin
                    Review.Points[PI].Height:=H;Review.Points[PI].HasHeight:=True;
                  end;
                end;
              end;
            end;
          end;
          for I in Pair.Value do
            if(FWays[I]<>0)and not Review.Points[I].HasHeight then Include(Review.Points[I].Issues,rcSurface);
        finally Obstacles.Free;ByWay.Free end;
        Inc(Review.CheckedTiles);
      finally Model.Free end;
      FLock.Enter;try FResult.Tiles:=Review.Tiles;FResult.CheckedTiles:=Review.CheckedTiles;finally FLock.Leave end;
    end;
    ReviewHeightSteps(Review);
    FLock.Enter;try FResult:=Review;finally FLock.Leave end;
  finally TilePoints.Free;Cache.Free;Proj.Free end;
end;
procedure Shutdown;
var I:Integer;
begin
  TasksLock.Enter;try for I:=0 to Tasks.Count-1 do TRouteReviewTask(Tasks[I]).Terminate;finally TasksLock.Leave end;
  Idle.WaitFor(INFINITE);
  { Idle is signalled while UnregisterTask still holds this lock. Wait for
    that final Leave before finalization destroys the critical section. }
  TasksLock.Enter;TasksLock.Leave;
end;
initialization
  Tasks:=TList.Create;TasksLock:=TCriticalSection.Create;Idle:=TEvent.Create(nil,True,True,'');
finalization
  Shutdown;Tasks.Free;Idle.Free;TasksLock.Free;
end.
