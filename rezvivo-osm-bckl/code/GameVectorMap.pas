unit GameVectorMap;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, SysUtils, fpjson, CastleUIControls, CastleVectors, CastleRectangles,
  CastleGLUtils, CastleFonts, CastleGLImages, CastleGLShaders, CastleRenderContext,
  Osm3dGeoMath, Osm3dVectorMap, Osm3dFlatMap, GameGlobeMath;
const VECTOR_MAP_MIN_ZOOM = 0;
type
  TVectorMapTile=class
    Tile:TTileXY; Data,SeedData:TMapVectorData; Task:TFlatMapVectorTask;
    Needed:Boolean; Used,RetryAt:QWord;
    destructor Destroy;override;
  end;
  TMapDrawVertex=packed record
    Position,Endpoint:TVector2; Color:TVector4; Local,Extent:TVector2;
  end;
  TMapPlacedLabel=record
    Key,Caption:string; Anchor:TLatLon;
    Size,Width,Angle,Alpha:Single; Color:TVector4; Wanted:Boolean;
  end;
  TVectorMap=class(TCastleUserInterface)
  private
    FTiles,FSorted:TList; FView:TGlobeProjection; FRect:TFloatRectangle; FBounds,FGeometryBounds:TLatLonBox;
    FAnchor:TLatLon;
    FGeometryZoom:Integer;
    FSourceZoom:Integer;
    FScale,FLayoutDelay,FGeometryDelay,FZoom:Single; FEnabled,FLoadingPaused,FDirty,FLabelDirty,FDataDirty,FUpload:Boolean;
    FVertices:array of TMapDrawVertex; FVertexCount:Integer;
    FLabels:array of TMapPlacedLabel; FLabelCount,FVisibleFeatures:Integer;
    FFont:TCastleFont; FAtlas:TDrawableImage; FFontShader,FShader:TGLSLProgram;
    FVao:TVertexArrayObject; FBuffer:Cardinal;
    FPosition,FEndpoint,FColor,FLocal,FExtent:TGLSLAttribute;
    FBuilds,FUploads:QWord; FBuildMs:Double;
    procedure RebuildFeatures;
    procedure BuildGeometry;
    procedure PlaceLabels;
    procedure DrawLabels;
    procedure EnsureFont;
    procedure Vertex(const P,Endpoint:TVector2;const C:TVector4;const L,E:TVector2);
    procedure Segment(const A,B:TVector2;LineSize,CasingSize:Single;const Color:TVector4);
    function Project(const P:TLatLon):TVector2;
    function FeatureVisible(F:TMapVectorFeature):Boolean;
    procedure ReleaseGpu;
  public
    procedure GLContextClose;override;
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure Prepare(const View:TGlobeProjection;const Rect:TFloatRectangle;
      Scale,SecondsPassed:Single;Enabled,Paused:Boolean);
    procedure StopLoading;
    function Idle:Boolean;
    function Stats:TJSONObject;
    procedure Render;override;
  end;
implementation
uses Math, Generics.Collections, CastleColors, CastleTextureFontData,
  CastleUnicode, CastleTimeUtils, CastleRenderOptions, CastleGL,
  Osm3dStudioSettings, Osm3dOsmOverpass, Osm3dMapOverview, Osm3dMapWorld;

const
  MapVS='attribute vec2 position; attribute vec2 endpoint; attribute vec4 vertex_color;'+LineEnding+
    'attribute vec2 local; attribute vec2 extent; uniform vec4 viewport;'+LineEnding+
    'uniform vec4 map_rect; uniform vec4 globe; uniform vec4 center; uniform vec3 style;'+LineEnding+
    'varying vec4 tint; varying vec2 p; varying vec2 shape; varying float face;'+LineEnding+
    'vec2 project(vec2 ll){float a=ll.y+center.z; float d=ll.y-center.y; float l=ll.x-center.x;'+
    'float c=cos(a); float h=sin(l*0.5); float q=2.0*h*h; float v=sin(d*0.5);'+
    'float z=-2.0*v*v-globe.x*c*q; vec2 xy=vec2(c*sin(l),sin(d)+globe.y*c*q);'+
    'face=z+globe.z/(1.0+globe.z); return map_rect.xy+map_rect.zw*0.5+xy*(globe.w/(globe.z-z));}'+LineEnding+
    'void main(){vec2 a=project(position); shape=vec2(0.0,-1.0); p=vec2(0.0);'+
    'if(extent.y>=0.0){vec2 b=project(endpoint); vec2 d=b-a; float len=length(d);'+
    'vec2 u=d/max(len,0.001); float h=(extent.x*style.y+extent.y)*style.x*0.5;'+
    'p=local*vec2(len*0.5+h+1.0,h+1.0); shape=vec2(len*0.5,h);'+
    'a=(a+b)*0.5+u*p.x+vec2(-u.y,u.x)*p.y;}'+
    'gl_Position=vec4((a-viewport.xy)*2.0/viewport.zw-1.0,0.0,1.0);'+
    'tint=vec4(vertex_color.rgb,extent.y< -1.5?vertex_color.a:clamp((style.z-vertex_color.a+0.25)*2.0,0.0,1.0));}';
  MapFS='varying vec4 tint; varying vec2 p; varying vec2 shape; varying float face;'+LineEnding+
    'void main(){if(face<0.0)discard; float a=1.0; if(shape.y>=0.0){'+
    'float d=length(vec2(max(abs(p.x)-shape.x,0.0),p.y))-shape.y;'+
    'a=clamp(0.5-d,0.0,1.0);} gl_FragColor=vec4(tint.rgb,tint.a*a);}';
  FontFS='#ifdef GL_ES'+LineEnding+'#if __VERSION__ < 300'+LineEnding+
    '#extension GL_OES_standard_derivatives : enable'+LineEnding+'#endif'+LineEnding+
    'precision mediump float;'+LineEnding+'precision highp int;'+LineEnding+'#endif'+LineEnding+
    'varying vec2 tex_coord_frag; uniform sampler2D image_texture; uniform vec4 color;'+LineEnding+
    'void main(){ float d=texture2D(image_texture,tex_coord_frag).a;'+
    'float w=max(fwidth(d),0.001); float ink=smoothstep(0.5-w*0.55,0.5+w*0.55,d);'+
    'float halo=smoothstep(0.5-w*2.0,0.5-w*0.8,d);'+
    'gl_FragColor=vec4(mix(vec3(0.99,0.985,0.965),color.rgb,ink),halo*color.a); }';

function MapColor(Value:LongWord):TVector4;
begin Result:=Vector4(((Value shr 16)and 255)/255,((Value shr 8)and 255)/255,(Value and 255)/255,1);end;
function FeatureOrder(F:TMapVectorFeature):Integer;
begin
  Result:=Ord(F.Kind)*10;
  if (F.Kind>=mfWaterway)and(F.Kind<=mfMotorway)then Result:=Result+F.Layer*1000;
end;
function CompareFeatures(A,B:Pointer):Integer;
var X,Y:TMapVectorFeature;
begin
  X:=TMapVectorFeature(A);Y:=TMapVectorFeature(B);Result:=FeatureOrder(X)-FeatureOrder(Y);
  if Result=0 then Result:=CompareStr(X.Key,Y.Key);
end;
function CompareLabels(A,B:Pointer):Integer;
var X,Y:TMapVectorFeature;
begin
  X:=TMapVectorFeature(A);Y:=TMapVectorFeature(B);Result:=Y.LabelPriority-X.LabelPriority;
  if Result=0 then begin
    if Y.Population>X.Population then Result:=1 else if Y.Population<X.Population then Result:=-1;
  end;
  if Result=0 then Result:=CompareStr(X.Key,Y.Key);
end;

destructor TVectorMapTile.Destroy;
begin Task.Free;Data.Free;SeedData.Free;inherited;end;
constructor TVectorMap.Create(AOwner:TComponent);
begin
  inherited;FTiles:=TList.Create;FSorted:=TList.Create;FullSize:=True;
  FDirty:=True;FDataDirty:=True;FScale:=1;
end;
destructor TVectorMap.Destroy;
var I:Integer;
begin
  StopLoading;
  for I:=0 to FTiles.Count-1 do TObject(FTiles[I]).Free;
  FTiles.Free;FSorted.Free;ReleaseGpu;FreeAndNil(FFont);inherited;
end;
procedure TVectorMap.ReleaseGpu;
begin
  FreeAndNil(FAtlas);FreeAndNil(FFontShader);FreeAndNil(FVao);FreeAndNil(FShader);
  if FBuffer<>0 then begin glDeleteBuffers(1,@FBuffer);FBuffer:=0;end;
  FUpload:=True;
end;
procedure TVectorMap.GLContextClose;
begin ReleaseGpu;inherited;end;
procedure TVectorMap.StopLoading;
var I:Integer;T:TVectorMapTile;
begin for I:=0 to FTiles.Count-1 do begin T:=TVectorMapTile(FTiles[I]);if T.Task<>nil then T.Task.Cancel;end;end;
function TVectorMap.Idle:Boolean;
var I:Integer;T:TVectorMapTile;
begin
  Result:=False;
  for I:=0 to FTiles.Count-1 do begin T:=TVectorMapTile(FTiles[I]);if(T.Task<>nil)and not T.Task.Done then Exit;end;
  Result:=True;
end;

procedure TVectorMap.Prepare(const View:TGlobeProjection;const Rect:TFloatRectangle;
  Scale,SecondsPassed:Single;Enabled,Paused:Boolean);
var B:TLatLonBox;I,J,X,Y,X0,X1,Y0,Y1,N,Active,RequiredZoom:Integer;T,Best:TVectorMapTile;Built:TMapVectorData;
    Changed:Boolean;NowTick:QWord;D,BestD:Double;CenterTile:TTileXY;Bytes:Int64;DataZoom:Integer;
  function Find(AX,AY:Integer):TVectorMapTile;
  var K:Integer;
  begin
    for K:=0 to FTiles.Count-1 do begin Result:=TVectorMapTile(FTiles[K]);if(Result.Tile.X=AX)and(Result.Tile.Y=AY)and(Result.Tile.Zoom=DataZoom)then Exit;end;
    Result:=TVectorMapTile.Create;Result.Tile:=TTileXY.Make(AX,AY,DataZoom);FTiles.Add(Result);
  end;
begin
  FEnabled:=Enabled and(View.NominalZoom>=VECTOR_MAP_MIN_ZOOM-0.05);
  FLoadingPaused:=Paused;
  Changed:=(FView.Center.Lat<>View.Center.Lat)or(FView.Center.Lon<>View.Center.Lon)or
    (FView.Altitude<>View.Altitude)or(FRect.Left<>Rect.Left)or(FRect.Bottom<>Rect.Bottom)or
    (FRect.Width<>Rect.Width)or(FRect.Height<>Rect.Height)or(FScale<>Scale);
  FView:=View;FRect:=Rect;FScale:=EnsureRange(Scale,0.85,2.0);
  FZoom:=View.NominalZoom;
  if Floor(FZoom+0.25)<>FGeometryZoom then begin FDirty:=True;FGeometryDelay:=0;end;
  { Request the classes that can actually appear at this scale. Raw OSM stays
    in the common cache; zooming in refines these lightweight map features. }
  RequiredZoom:=EnsureRange(Floor(FZoom+0.25),0,18);
  DataZoom:=MapSourceZoom(RequiredZoom);
  if DataZoom<>FSourceZoom then begin
    FSourceZoom:=DataZoom;FDataDirty:=True;FDirty:=True;FLabelDirty:=True;
  end;
  if Changed then FLabelDirty:=True;
  FBounds:=View.Bounds;
  if(FBounds.MinLat<FGeometryBounds.MinLat)or(FBounds.MaxLat>FGeometryBounds.MaxLat)or
    (FBounds.MinLon<FGeometryBounds.MinLon)or(FBounds.MaxLon>FGeometryBounds.MaxLon)then
    begin FDirty:=True;FGeometryDelay:=0;end;
  FGeometryDelay:=Max(0,FGeometryDelay-SecondsPassed);
  FLayoutDelay:=Max(0,FLayoutDelay-SecondsPassed);
  NowTick:=GetTickCount64;
  for I:=0 to FTiles.Count-1 do TVectorMapTile(FTiles[I]).Needed:=False;
  if FEnabled then begin
    B:=View.Bounds;N:=1 shl DataZoom;
    X0:=Floor((B.MinLon+180)/360*N);X1:=Floor((B.MaxLon+180)/360*N);
    Y0:=TTileMath.LatLonToTile(TLatLon.Make(Min(85.0511,B.MaxLat),0),DataZoom).Y;
    Y1:=TTileMath.LatLonToTile(TLatLon.Make(Max(-85.0511,B.MinLat),0),DataZoom).Y;
    for Y:=Max(0,Y0)to Min(N-1,Y1)do for X:=X0 to Min(X1,X0+N-1)do begin
      J:=((X mod N)+N)mod N;T:=Find(J,Y);T.Needed:=True;T.Used:=NowTick;
      { Keep regional names visible while OSM roads are fetched. This tiny
        read-only gazetteer is selected once per tile, never per frame. }
      if(DataZoom>=7)and(DataZoom<12)and(T.SeedData=nil)then begin
        T.SeedData:=BuildWorldMapVectors(nil,T.Tile,8);FDataDirty:=True;FDirty:=True;FLabelDirty:=True;
      end;
    end;
  end;
  Active:=0;
  for I:=0 to FTiles.Count-1 do begin
    T:=TVectorMapTile(FTiles[I]);if T.Task=nil then Continue;
    if not T.Needed or Paused then T.Task.Cancel;
    if T.Task.Done then begin
      Built:=T.Task.TakeData;FreeAndNil(T.Task);
      if Built<>nil then begin
        T.Data.Free;T.Data:=Built;FDataDirty:=True;FDirty:=True;FLabelDirty:=True;
      end
      else T.RetryAt:=NowTick+5000;
    end else Inc(Active);
  end;
  if FEnabled and not Paused then begin
    CenterTile:=TTileMath.LatLonToTile(View.Center,DataZoom);
    while Active<FlatMapWorkerLimit do begin
      Best:=nil;BestD:=1E30;
      for I:=0 to FTiles.Count-1 do begin
        T:=TVectorMapTile(FTiles[I]);
        if not T.Needed or(T.Task<>nil)or((T.Data<>nil)and(T.Data.MaxZoom>=RequiredZoom))or(T.RetryAt>NowTick)then Continue;
        D:=Abs(T.Tile.X-CenterTile.X);D:=Min(D,(1 shl DataZoom)-D);
        D:=Sqr(D)+Sqr(T.Tile.Y-CenterTile.Y);
        if D<BestD then begin Best:=T;BestD:=D;end;
      end;
      if Best=nil then Break;
      Best.Task:=TFlatMapVectorTask.Create(Best.Tile,DefaultCacheRoot,RequiredZoom);Best.Task.Start;Inc(Active);
    end;
  end;
  Bytes:=0;for I:=0 to FTiles.Count-1 do begin T:=TVectorMapTile(FTiles[I]);
    if T.Data<>nil then Inc(Bytes,T.Data.Bytes);
    if T.SeedData<>nil then Inc(Bytes,T.SeedData.Bytes);
  end;
  repeat
    Best:=nil;
    if (FTiles.Count<=512)and(Bytes<=96*1024*1024)then Break;
    for I:=0 to FTiles.Count-1 do begin T:=TVectorMapTile(FTiles[I]);
      if not T.Needed and(T.Task=nil)and((Best=nil)or(T.Used<Best.Used))then Best:=T;
    end;
    if Best=nil then Break;
    if Best.Data<>nil then Dec(Bytes,Best.Data.Bytes);
    if Best.SeedData<>nil then Dec(Bytes,Best.SeedData.Bytes);
    FSorted.Clear;FTiles.Remove(Best);Best.Free;FDataDirty:=True;FDirty:=True;FLabelDirty:=True;
  until False;
  for I:=0 to High(FLabels)do begin
    if FLabels[I].Wanted and FEnabled then FLabels[I].Alpha:=Min(1,FLabels[I].Alpha+SecondsPassed/0.18)
    else FLabels[I].Alpha:=Max(0,FLabels[I].Alpha-SecondsPassed/0.12);
  end;
end;

procedure TVectorMap.RebuildFeatures;
var Seen:specialize TDictionary<string,Boolean>;I,J:Integer;T:TVectorMapTile;F:TMapVectorFeature;Data:TMapVectorData;
begin
  FSorted.Clear;Seen:=specialize TDictionary<string,Boolean>.Create;
  try
    for I:=0 to FTiles.Count-1 do begin T:=TVectorMapTile(FTiles[I]);
      Data:=T.Data;if Data=nil then Data:=T.SeedData;
      if(Data=nil)or(T.Tile.Zoom<>FSourceZoom)then Continue;
      for J:=0 to Data.Features.Count-1 do begin F:=TMapVectorFeature(Data.Features[J]);
        if Seen.ContainsKey(F.Key)then Continue;Seen.Add(F.Key,True);FSorted.Add(F);
      end;
    end;
    FSorted.Sort(@CompareFeatures);
  finally Seen.Free;end;
  FDataDirty:=False;
end;
function TVectorMap.Project(const P:TLatLon):TVector2;
var X,Y:Double;
begin
  if FView.Project(P,X,Y)then Result:=Vector2(FRect.Left+X,FRect.Bottom+Y)
  else Result:=Vector2(-1E10,-1E10);
end;
function TVectorMap.FeatureVisible(F:TMapVectorFeature):Boolean;
var B:TLatLonBox;
begin
  if FZoom<F.MinZoom-0.25 then Exit(False);
  B:=FBounds;
  Result:=(F.Bounds.MaxLat>=B.MinLat)and(F.Bounds.MinLat<=B.MaxLat)and
    ((F.Bounds.MaxLon>=B.MinLon)and(F.Bounds.MinLon<=B.MaxLon)or(B.MinLon< -180)or(B.MaxLon>180));
end;
procedure TVectorMap.Vertex(const P,Endpoint:TVector2;const C:TVector4;const L,E:TVector2);
begin
  if FVertexCount=Length(FVertices)then SetLength(FVertices,Max(4096,FVertexCount*2));
  FVertices[FVertexCount].Position:=P;FVertices[FVertexCount].Endpoint:=Endpoint;
  FVertices[FVertexCount].Color:=C;
  FVertices[FVertexCount].Local:=L;FVertices[FVertexCount].Extent:=E;Inc(FVertexCount);
end;
procedure TVectorMap.Segment(const A,B:TVector2;LineSize,CasingSize:Single;const Color:TVector4);
var E:TVector2;
  procedure Corner(X,Y:Single);
  begin Vertex(A,B,Color,Vector2(X,Y),E);end;
begin
  if(A.X=B.X)and(A.Y=B.Y)then Exit;
  E:=Vector2(LineSize,CasingSize);
  Corner(-1,-1);Corner(1,-1);Corner(1,1);
  Corner(-1,-1);Corner(1,1);Corner(-1,1);
end;

procedure TVectorMap.BuildGeometry;
var I,J,First,Last,Pass:Integer;F:TMapVectorFeature;P:array of TVector2;VisibleItems:TList;
    ClipMin,ClipMax:TVector2;
    C:TVector4;W,Extra:Single;Started:TTimerResult;
  procedure DrawShade;
  const N=MAP_SHADE_SIDE;
  var TI,X,Y:Integer;T:TVectorMapTile;Q:TVector2;LL:TLatLon;G:Single;B:TLatLonBox;
    procedure Corner(U,V:Integer);
    begin
      LL.Lon:=(T.Tile.X+U/(N-1))/(1 shl T.Tile.Zoom)*360-180;
      LL.Lat:=ArcTan(Sinh(Pi*(1-2*(T.Tile.Y+V/(N-1))/(1 shl T.Tile.Zoom))))*180/Pi;
      Q:=Vector2(GlobeWrapLon(LL.Lon-FAnchor.Lon)*Pi/180,(LL.Lat-FAnchor.Lat)*Pi/180);
      G:=T.Data.Shade[V*N+U];
      { A neutral transparent overlay preserves every map material and leaves
        roads/labels crisp. It is built once with geometry, never per frame. }
      Vertex(Q,Vector2(0,0),Vector4(0,0,0,EnsureRange(1-G,0.0,0.45)),Vector2(0,0),Vector2(0,-2));
    end;
  begin
    for TI:=0 to FTiles.Count-1 do begin
      T:=TVectorMapTile(FTiles[TI]);
      if(T.Tile.Zoom<>FSourceZoom)or(T.Data=nil)or(Length(T.Data.Shade)<>N*N)then Continue;
      B:=TTileMath.TileToLatLonBox(T.Tile);
      if(B.MaxLat<FGeometryBounds.MinLat)or(B.MinLat>FGeometryBounds.MaxLat)then Continue;
      if(FGeometryBounds.MinLon>=-180)and(FGeometryBounds.MaxLon<=180)and
        ((B.MaxLon<FGeometryBounds.MinLon)or(B.MinLon>FGeometryBounds.MaxLon))then Continue;
      for Y:=0 to N-2 do for X:=0 to N-2 do begin
        Corner(X,Y);Corner(X+1,Y);Corner(X+1,Y+1);
        Corner(X,Y);Corner(X+1,Y+1);Corner(X,Y+1);
      end;
    end;
  end;
  procedure DrawFeature(Feature:TMapVectorFeature;Casing:Boolean);
  var Q,R:Integer;A,B,D:TVector2;
  begin
    F:=Feature;
    SetLength(P,Length(F.Points));
    for Q:=0 to High(P)do P[Q]:=Vector2(
      GlobeWrapLon(F.Points[Q].Lon-FAnchor.Lon)*Pi/180,(F.Points[Q].Lat-FAnchor.Lat)*Pi/180);
    case F.Kind of
      mfResidential:C:=MapColor($E8E5DF);mfIndustrial:C:=MapColor($E2DDE1);
      mfFarmland:C:=MapColor($E9E5CC);mfGrass:C:=MapColor($D6E5C4);
      mfForest:C:=MapColor($BBD5B2);mfSand:C:=MapColor($F2E6C5);
      mfWater,mfWaterway:C:=MapColor($AED3E1);mfBuilding:C:=MapColor($D2C9BF);
      mfRail:C:=MapColor($91918D);mfPath:C:=MapColor($B6A17B);
      mfService,mfStreet,mfTertiary:C:=MapColor($FFFFFF);
      mfSecondary:C:=MapColor($FFF4BD);mfPrimary:C:=MapColor($FFE7A2);
      mfTrunk:C:=MapColor($F8D3A4);mfMotorway:C:=MapColor($F2B6AF);
    end;
    C.W:=F.MinZoom;
    if Length(F.Triangles)>0 then begin
      Q:=0;
      while Q<Length(F.Triangles)do begin
        A:=P[F.Triangles[Q]];B:=P[F.Triangles[Q+1]];D:=P[F.Triangles[Q+2]];
        if(Max(A.X,Max(B.X,D.X))>=ClipMin.X)and(Min(A.X,Min(B.X,D.X))<=ClipMax.X)and
          (Max(A.Y,Max(B.Y,D.Y))>=ClipMin.Y)and(Min(A.Y,Min(B.Y,D.Y))<=ClipMax.Y)then
          for R:=Q to Q+2 do Vertex(P[F.Triangles[R]],Vector2(0,0),C,Vector2(0,0),Vector2(0,-1));
        Inc(Q,3);
      end;
    end else if Length(P)>1 then begin
      case F.Kind of
        mfWaterway:W:=2.1;mfRail:W:=1.2;mfPath:W:=1.3;mfService:W:=2.8;
        mfStreet:W:=4.2;mfTertiary:W:=4.8;mfSecondary:W:=5.5;
        mfPrimary:W:=6.2;mfTrunk:W:=6.8;mfMotorway:W:=7.5;
        else W:=1;
      end;
      Extra:=0;
      if Casing then begin C:=MapColor($B9B2A6);C.W:=F.MinZoom;Extra:=1.5;end;
      for Q:=1 to High(P)do begin
        A:=P[Q-1];B:=P[Q];
        if(Max(A.X,B.X)>=ClipMin.X)and(Min(A.X,B.X)<=ClipMax.X)and
          (Max(A.Y,B.Y)>=ClipMin.Y)and(Min(A.Y,B.Y)<=ClipMax.Y)then Segment(A,B,W,Extra,C);
      end;
    end;
    if not Casing then Inc(FVisibleFeatures);
  end;
begin
  Started:=Timer;FVertexCount:=0;FVisibleFeatures:=0;FAnchor:=FView.Center;
  FGeometryZoom:=Floor(FZoom+0.25);
  FGeometryBounds:=FBounds;
  { A small geographic guard band allows panning without rebuilding. Projection,
    zoom, line thickness and edge antialiasing are calculated on the GPU. }
  FGeometryBounds.MinLat:=FBounds.MinLat-(FBounds.MaxLat-FBounds.MinLat)*0.25;
  FGeometryBounds.MaxLat:=FBounds.MaxLat+(FBounds.MaxLat-FBounds.MinLat)*0.25;
  FGeometryBounds.MinLon:=FBounds.MinLon-(FBounds.MaxLon-FBounds.MinLon)*0.25;
  FGeometryBounds.MaxLon:=FBounds.MaxLon+(FBounds.MaxLon-FBounds.MinLon)*0.25;
  ClipMin:=Vector2((FGeometryBounds.MinLon-FAnchor.Lon)*Pi/180,(FGeometryBounds.MinLat-FAnchor.Lat)*Pi/180);
  ClipMax:=Vector2((FGeometryBounds.MaxLon-FAnchor.Lon)*Pi/180,(FGeometryBounds.MaxLat-FAnchor.Lat)*Pi/180);
  VisibleItems:=TList.Create;
  try
    for I:=0 to FSorted.Count-1 do begin
      F:=TMapVectorFeature(FSorted[I]);if(F.Kind>=mfPlace)or(F.MinZoom>FGeometryZoom)then Continue;
      if(F.Bounds.MaxLat>=FGeometryBounds.MinLat)and(F.Bounds.MinLat<=FGeometryBounds.MaxLat)and
        (((F.Bounds.MaxLon>=FGeometryBounds.MinLon)and(F.Bounds.MinLon<=FGeometryBounds.MaxLon))or
        (FGeometryBounds.MinLon< -180)or(FGeometryBounds.MaxLon>180))then VisibleItems.Add(F);
    end;
    { Same-layer road casings precede all their fills: no seams at junctions. }
    for I:=0 to VisibleItems.Count-1 do begin F:=TMapVectorFeature(VisibleItems[I]);if F.Kind<=mfBuilding then DrawFeature(F,False);end;
    DrawShade;
    I:=0;
    while I<VisibleItems.Count do begin
      F:=TMapVectorFeature(VisibleItems[I]);First:=I;Last:=I+1;
      while Last<VisibleItems.Count do begin
        if FeatureOrder(TMapVectorFeature(VisibleItems[Last]))<>FeatureOrder(F)then Break;
        Inc(Last);
      end;
      if(F.Kind>=mfWaterway)and(F.Kind<=mfMotorway)then
        for Pass:=0 to 1 do begin
          if(Pass=0)and(F.Kind<mfService)then Continue;
          for J:=First to Last-1 do DrawFeature(TMapVectorFeature(VisibleItems[J]),Pass=0);
        end;
      I:=Last;
    end;
  finally VisibleItems.Free;end;
  if Length(FVertices)>Max(16384,FVertexCount*3)then SetLength(FVertices,Max(4096,FVertexCount+FVertexCount div 4));
  FDirty:=False;FUpload:=True;FGeometryDelay:=0.15;
  Inc(FBuilds);FBuildMs:=TimerSeconds(Timer,Started)*1000;
end;

procedure TVectorMap.EnsureFont;
var I:Integer;Chars:UnicodeString;
begin
  if FFont<>nil then Exit;
  FFont:=TCastleFont.Create(nil);FFont.OptimalSize:=32;FFont.DistanceField:=True;
  Chars:='';for I:=$A0 to $24F do Chars:=Chars+WideChar(I);
  for I:=$370 to $52F do Chars:=Chars+WideChar(I);
  FFont.LoadCharacters:=UTF8Encode(Chars+UnicodeString(#$2013#$2014#$2026#$2116));
  FFont.Url:='castle-data:/menu/fonts/DejaVuSans.ttf';
end;

procedure TVectorMap.PlaceLabels;
type TBox=record L,B,R,T:Single;end;
var Candidates:TList;Boxes:array of TBox;Used:Integer;
    Names:specialize TDictionary<string,Boolean>;
    I,J,K,Idx,TryAnchor:Integer;F:TMapVectorFeature;P,U,V:TVector2;
    W,H,Angle,Len,Total,AtDist,T,DX,DY:Single;B:TBox;Fits:Boolean;
    Points:array of TVector2;Lengths:array of Single;Geo:TLatLon;
  function Along(D:Single):TVector2;
  var A:Integer;S:Single;
  begin
    S:=0;Result:=Points[High(Points)];
    for A:=1 to High(Points)do begin
      if(S+Lengths[A]>=D)and(Lengths[A]>0)then Exit(Points[A-1]+(Points[A]-Points[A-1])*((D-S)/Lengths[A]));
      S:=S+Lengths[A];
    end;
  end;
begin
  EnsureFont;Candidates:=TList.Create;Names:=specialize TDictionary<string,Boolean>.Create;
  try
    for I:=0 to High(FLabels)do FLabels[I].Wanted:=False;
    for I:=0 to FSorted.Count-1 do begin F:=TMapVectorFeature(FSorted[I]);
      if(F.Caption<>'')and(FView.NominalZoom>=F.LabelZoom)and FeatureVisible(F)then Candidates.Add(F);
    end;
    Candidates.Sort(@CompareLabels);SetLength(Boxes,400);Used:=0;
    for I:=0 to Candidates.Count-1 do begin
      F:=TMapVectorFeature(Candidates[I]);
      if Used=Length(Boxes)then Break;
      if Names.ContainsKey(F.Caption)then Continue;
      H:=12*FScale;
      if F.Kind=mfPlace then H:=EnsureRange(15+(F.LabelPriority-90)*0.12,14.0,19.0)*FScale;
      if F.Kind=mfHouseNumber then H:=10.5*FScale;
      if F.Kind in [mfRegion,mfMarineLabel] then H:=13*FScale;
      FFont.Size:=H;W:=FFont.TextWidth(F.Caption);
      if W>Min(340*FScale,FRect.Width*0.65)then Continue;
      Angle:=0;Geo:=F.Bounds.Center;P:=Project(Geo);Fits:=False;
      if(F.Kind>=mfWaterway)and(F.Kind<=mfMotorway)then begin
        SetLength(Points,Length(F.Points));SetLength(Lengths,Length(F.Points));Total:=0;
        for J:=0 to High(Points)do begin Points[J]:=Project(F.Points[J]);Lengths[J]:=0;
          if J>0 then begin Lengths[J]:=Sqrt(Sqr(Points[J].X-Points[J-1].X)+Sqr(Points[J].Y-Points[J-1].Y));Total:=Total+Lengths[J];end;
        end;
        if Total<W+30*FScale then Continue;
      end else Total:=0;
      { Multiple world-anchored candidates, deterministic across tile arrival.
        Text stays upright and is accepted only on a sufficiently straight run. }
      for TryAnchor:=0 to 4 do begin
        if Total>0 then begin
          case TryAnchor of 0:T:=0.5;1:T:=0.25;2:T:=0.75;3:T:=0.125;else T:=0.875;end;
          AtDist:=EnsureRange(Total*T,W/2+8,Total-W/2-8);
          U:=Along(AtDist-W/2);V:=Along(AtDist+W/2);P:=Along(AtDist);
          Len:=Sqrt(Sqr(V.X-U.X)+Sqr(V.Y-U.Y));
          if Len<W*0.96 then Continue;
          if Sqr(P.X-(U.X+V.X)/2)+Sqr(P.Y-(U.Y+V.Y)/2)>Sqr(3*FScale)then Continue;
          Angle:=ArcTan2(V.Y-U.Y,V.X-U.X);
          if Angle>Pi/2 then Angle:=Angle-Pi else if Angle< -Pi/2 then Angle:=Angle+Pi;
          if not FView.Pick(P.X-FRect.Left,P.Y-FRect.Bottom,Geo)then Continue;
        end else if TryAnchor>0 then Break;
        DX:=(Abs(Cos(Angle))*W+Abs(Sin(Angle))*H)/2+5*FScale;
        DY:=(Abs(Sin(Angle))*W+Abs(Cos(Angle))*H)/2+4*FScale;
        B.L:=P.X-DX;B.R:=P.X+DX;B.B:=P.Y-DY;B.T:=P.Y+DY;
        if(B.L<FRect.Left+4)or(B.R>FRect.Right-4)or(B.B<FRect.Bottom+4)or(B.T>FRect.Top-4)then Continue;
        Fits:=True;
        for J:=0 to Used-1 do if(B.L<Boxes[J].R)and(B.R>Boxes[J].L)and(B.B<Boxes[J].T)and(B.T>Boxes[J].B)then begin Fits:=False;Break;end;
        if Fits then Break;
      end;
      if not Fits then Continue;
      Boxes[Used]:=B;Inc(Used);Names.Add(F.Caption,True);Idx:=-1;
      for J:=0 to High(FLabels)do if FLabels[J].Key=F.Key then begin Idx:=J;Break;end;
      if Idx<0 then begin Idx:=Length(FLabels);SetLength(FLabels,Idx+1);FLabels[Idx].Key:=F.Key;end;
      FLabels[Idx].Caption:=F.Caption;FLabels[Idx].Anchor:=Geo;FLabels[Idx].Size:=H;
      FLabels[Idx].Width:=W;FLabels[Idx].Angle:=Angle;FLabels[Idx].Wanted:=True;
      FLabels[Idx].Color:=MapColor($454C48);
      if(F.Kind=mfWater)or(F.Kind=mfWaterway)then FLabels[Idx].Color:=MapColor($467A94);
      if(F.Kind=mfForest)or(F.Kind=mfGrass)then FLabels[Idx].Color:=MapColor($50744B);
      if F.Kind=mfRegion then FLabels[Idx].Color:=MapColor($776347);
      if F.Kind=mfMarineLabel then FLabels[Idx].Color:=MapColor($34657F);
    end;
    K:=0;for I:=0 to High(FLabels)do if FLabels[I].Wanted or(FLabels[I].Alpha>0)then begin FLabels[K]:=FLabels[I];Inc(K);end;
    SetLength(FLabels,K);FLabelCount:=Used;FLayoutDelay:=0.1;
  finally Names.Free;Candidates.Free;end;
end;

procedure TVectorMap.DrawLabels;
var I,Padding:Integer;It:TCastleStringIterator;G:TTextureFontData.TGlyph;
    P,C:TVector2;S,X,Y,A,Co,Si:Single;R,Screen:TFloatRectangle;Color:TVector4;
begin
  if FFont=nil then Exit;
  if FAtlas=nil then begin
    FAtlas:=TDrawableImage.Create(FFont.FontData.Image,True,False);
    FFontShader:=TGLSLProgram.Create;
    FFontShader.AttachVertexShader({$I image.vs.inc});FFontShader.AttachFragmentShader(FontFS);FFontShader.Link;
    FAtlas.CustomShader:=FFontShader;
  end;
  TDrawableImage.BatchingBegin;
  try
  for I:=0 to High(FLabels)do begin
    if FLabels[I].Alpha<=0 then Continue;
    P:=Project(FLabels[I].Anchor);S:=FLabels[I].Size/FFont.OptimalSize;
    { Include enough SDF padding for the screen-space halo, even on small text.
      Leave a texel between this glyph and its neighbours in the atlas. }
    A:=FLabels[I].Angle;Co:=Cos(A);Si:=Sin(A);
    Color:=FLabels[I].Color;Color.W:=FLabels[I].Alpha;FAtlas.Color:=Color;
    FAtlas.Rotation:=A;X:=-FLabels[I].Width/2;Y:=-FLabels[I].Size*0.35;
    It.Start(FLabels[I].Caption);
    while It.GetNext do begin
      G:=FFont.FontData.Glyph(It.Current);if G=nil then Continue;
      R:=FloatRectangle(FFont.FontData.GlyphDrawImageRect(G));
      Padding:=Max(0,Min((G.Width-Round(R.Width))div 2-1,Ceil(2/S)));
      R.Left:=R.Left-Padding;R.Bottom:=R.Bottom-Padding;
      R.Width:=R.Width+2*Padding;R.Height:=R.Height+2*Padding;
      C:=Vector2(X-(G.X+Padding)*S+R.Width*S/2,Y-(G.Y+Padding)*S+R.Height*S/2);
      Screen:=FloatRectangle(P.X+Co*C.X-Si*C.Y-R.Width*S/2,P.Y+Si*C.X+Co*C.Y-R.Height*S/2,R.Width*S,R.Height*S);
      FAtlas.Draw(Screen,R);X:=X+G.AdvanceX*S;Y:=Y+G.AdvanceY*S;
    end;
  end;
  finally TDrawableImage.BatchingEnd;end;
end;

procedure TVectorMap.Render;
var Clip:TScissor;
begin
  inherited;if not FEnabled then Exit;
  if FDirty and(FGeometryDelay=0)then begin
    if FDataDirty then RebuildFeatures;
    BuildGeometry;
  end;
  if FLabelDirty and not FDataDirty and(FLayoutDelay=0)then begin PlaceLabels;FLabelDirty:=False;end;
  Clip:=TScissor.Create;Clip.Rect:=Rectangle(Round(FRect.Left),Round(FRect.Bottom),Round(FRect.Width),Round(FRect.Height));Clip.Enabled:=True;
  try
    TDrawableImage.BatchingFlush;
    if FVertexCount>0 then begin
      if FShader=nil then begin
        FShader:=TGLSLProgram.Create;FShader.AttachVertexShader(MapVS);FShader.AttachFragmentShader(MapFS);FShader.Link;
        FPosition:=FShader.Attribute('position');FEndpoint:=FShader.Attribute('endpoint');FColor:=FShader.Attribute('vertex_color');
        FLocal:=FShader.Attribute('local');FExtent:=FShader.Attribute('extent');
        FVao:=TVertexArrayObject.Create(nil);glGenBuffers(1,@FBuffer);FUpload:=True;
      end;
      RenderContext.CurrentProgram:=FShader;RenderContext.CurrentVao:=FVao;
      RenderContext.BindBuffer[btArray]:=FBuffer;
      if FUpload then begin glBufferData(GL_ARRAY_BUFFER,FVertexCount*SizeOf(TMapDrawVertex),@FVertices[0],GL_DYNAMIC_DRAW);FUpload:=False;Inc(FUploads);end;
      FPosition.EnableArrayVector2(FVao,SizeOf(TMapDrawVertex),0);
      FEndpoint.EnableArrayVector2(FVao,SizeOf(TMapDrawVertex),SizeOf(TVector2));
      FColor.EnableArrayVector4(FVao,SizeOf(TMapDrawVertex),2*SizeOf(TVector2));
      FLocal.EnableArrayVector2(FVao,SizeOf(TMapDrawVertex),2*SizeOf(TVector2)+SizeOf(TVector4));
      FExtent.EnableArrayVector2(FVao,SizeOf(TMapDrawVertex),3*SizeOf(TVector2)+SizeOf(TVector4));
      FShader.Uniform('viewport').SetValue(Vector4(RenderContext.Viewport.Left,RenderContext.Viewport.Bottom,RenderContext.Viewport.Width,RenderContext.Viewport.Height));
      FShader.Uniform('map_rect').SetValue(Vector4(FRect.Left,FRect.Bottom,FRect.Width,FRect.Height));
      FShader.Uniform('globe').SetValue(Vector4(Cos(FView.Center.Lat*Pi/180),Sin(FView.Center.Lat*Pi/180),FView.Altitude,FView.Focal));
      FShader.Uniform('center').SetValue(Vector4(GlobeWrapLon(FView.Center.Lon-FAnchor.Lon)*Pi/180,
        (FView.Center.Lat-FAnchor.Lat)*Pi/180,FAnchor.Lat*Pi/180,0));
      FShader.Uniform('style').SetValue(Vector3(FScale,Power(1.3,EnsureRange(FZoom-15,-4.0,3.0)),FZoom));
      RenderContext.BlendingEnable(bsSrcAlpha,bdOneMinusSrcAlpha);
      glDrawArrays(GL_TRIANGLES,0,FVertexCount);
      FPosition.DisableArray;FEndpoint.DisableArray;FColor.DisableArray;FLocal.DisableArray;FExtent.DisableArray;
      RenderContext.BindBuffer[btArray]:=0;RenderContext.BlendingDisable;
    end;
    DrawLabels;TDrawableImage.BatchingFlush;
  finally Clip.Free;end;
end;
function TVectorMap.Stats:TJSONObject;
var I,Ready,Pending,Wanted,ReadyVisible,SeedVisible,Terrain:Integer;Bytes:Int64;T:TVectorMapTile;
begin
  Ready:=0;Pending:=0;Wanted:=0;Bytes:=0;ReadyVisible:=0;SeedVisible:=0;Terrain:=0;
  for I:=0 to FTiles.Count-1 do begin T:=TVectorMapTile(FTiles[I]);
    if T.Data<>nil then begin Inc(Ready);Inc(Bytes,T.Data.Bytes);end;
    if T.SeedData<>nil then begin
      Inc(Bytes,T.SeedData.Bytes);
      if T.Needed and(T.Data=nil)then Inc(SeedVisible);
    end;
    if T.Needed and(T.Data<>nil)then begin
      Inc(ReadyVisible);if Length(T.Data.Shade)>0 then Inc(Terrain);
    end;
    if T.Task<>nil then Inc(Pending);if T.Needed then Inc(Wanted);
  end;
  Result:=TJSONObject.Create(['enabled',FEnabled,'source_zoom',FSourceZoom,
    'ready',Ready,'ready_visible',ReadyVisible,'seed_ready_visible',SeedVisible,'terrain',Terrain,'pending',Pending,'wanted',Wanted,'features',FSorted.Count,
    'visible_features',FVisibleFeatures,'labels',FLabelCount,'vertices',FVertexCount,
    'cpu_bytes',Bytes+Int64(Length(FVertices))*SizeOf(TMapDrawVertex),
    'geometry_builds',Int64(FBuilds),'gpu_uploads',Int64(FUploads),'build_ms',FBuildMs]);
end;
end.
