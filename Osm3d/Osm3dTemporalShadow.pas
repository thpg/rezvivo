unit Osm3dTemporalShadow;
{$mode objfpc}{$H+}
interface
uses CastleVectors, CastleTransform, CastleRenderOptions, Osm3dForestShadowCache, fpjson;
type
  { Interleaved caster buckets. Cached depth is reprojected, never blended
    with the previous silhouette of the SAME object. Riders are excluded. }
  TTemporalWorldShadow = class
  private
    FMaps:array[0..3,0..3]of TShadowDepthCache;
    FStatic:array[0..3]of TShadowDepthCache;
    FStaticReady:array[0..3]of Boolean;
    FCompositor:TShadowDepthCache;
    FReady:array[0..3]of Boolean;
    FUpdated:array[0..3,0..3]of QWord;
    FAnimation:array[0..3,0..3]of Single;
    FTreeRevision:array[0..3,0..3]of QWord;
    FCaptureTick:array[0..3,0..3]of QWord;
    FCount,FSize,FFirstZone,FBucket:Integer;
    FFrame,FRevision,FCaptures,FComposites,FFallbacks:QWord;
    FStaticCaptures,FStaticReuses,FFrozenReuses,FCurrentTreeRevision,FComposeDraws:QWord;
    FSeparateStatic,FFrameFrozen:Boolean;
    FLastTick:QWord;
    FLastAnimation:Single;
    FDirection:TVector3;
  public
    destructor Destroy;override;
    procedure ContextClose;
    procedure BeginFrame(Count,Size:Integer;LiveNear,StaticDepth:Boolean;Revision,TreeRevision:QWord;
      const Direction:TVector3);
    procedure PrepareStatic(Zone:Integer;const Render:TRenderFromViewFunction;
      const Side,Up:TVector3;X,Y,Half,MinDepth,MaxDepth:Single);
    procedure PrepareZone(Zone:Integer;const Render:TRenderFromViewFunction;
      const Side,Up:TVector3;X,Y,Half,MinDepth,MaxDepth:Single);
    function Ready(Zone:Integer):Boolean;
    function StaticReady(Zone:Integer):Boolean;
    procedure SkipZone(Zone:Integer);
    procedure Draw(Zone:Integer;X,Y,Half,MinDepth,MaxDepth:Single);
    procedure Snapshot(J:TJSONObject);
    property Count:Integer read FCount;
    property SeparateStatic:Boolean read FSeparateStatic;
  end;
implementation
uses SysUtils,Math,Osm3dShadowSchedule,Osm3dWind;

destructor TTemporalWorldShadow.Destroy;
begin ContextClose;inherited;end;

procedure TTemporalWorldShadow.ContextClose;
var Z,B:Integer;
begin
  for Z:=0 to 3 do for B:=0 to 3 do FreeAndNil(FMaps[Z,B]);
  for Z:=0 to 3 do FreeAndNil(FStatic[Z]);
  FreeAndNil(FCompositor);
  FillChar(FReady,SizeOf(FReady),0);FillChar(FUpdated,SizeOf(FUpdated),0);
  FillChar(FStaticReady,SizeOf(FStaticReady),0);
  FCount:=0;
end;

procedure TTemporalWorldShadow.BeginFrame(Count,Size:Integer;LiveNear,StaticDepth:Boolean;
  Revision,TreeRevision:QWord;const Direction:TVector3);
var Z,B,First:Integer;Tick:QWord;Animation:Single;TimeJump,Frozen,WorldChanged:Boolean;
begin
  Tick:=GetTickCount64;Animation:=VegetationWindNow;
  Frozen:=VegetationWindFrozen and TemporalShadowFreezeReuse;
  TimeJump:=(FFrame>0) and ((Tick-FLastTick>1000) or (Abs(Animation-FLastAnimation)>1));
  FLastTick:=Tick;FLastAnimation:=Animation;
  First:=Ord(LiveNear);
  StaticDepth:=StaticDepth and (Count>0);
  if (Count<>FCount) or (Size<>FSize) or (First<>FFirstZone) or (StaticDepth<>FSeparateStatic) then ContextClose;
  FCount:=Count;FSize:=Size;FFirstZone:=First;
  FSeparateStatic:=StaticDepth;FCurrentTreeRevision:=TreeRevision;
  FillChar(FReady,SizeOf(FReady),0);
  FillChar(FStaticReady,SizeOf(FStaticReady),0);
  { A resume/seek must not mix silhouettes from two distant animation times. }
  WorldChanged:=(FRevision<>Revision) or ((Direction-FDirection).Length>0.0001);
  if WorldChanged then
    for Z:=0 to 3 do if FStatic[Z]<>nil then FStatic[Z].Invalidate;
  if TimeJump or WorldChanged or (FFrameFrozen and not Frozen) then
    for Z:=0 to 3 do for B:=0 to 3 do
      if FMaps[Z,B]<>nil then FMaps[Z,B].Invalidate;
  FRevision:=Revision;FDirection:=Direction;
  FFrameFrozen:=Frozen;
  FBucket:=ShadowPartitionForFrame(FFrame,Count);Inc(FFrame);
end;

procedure TTemporalWorldShadow.PrepareStatic(Zone:Integer;const Render:TRenderFromViewFunction;
  const Side,Up:TVector3;X,Y,Half,MinDepth,MaxDepth:Single);
begin
  if not FSeparateStatic then Exit;
  if FStatic[Zone]=nil then FStatic[Zone]:=TShadowDepthCache.Create;
  if FStatic[Zone].Covers(FDirection,X,Y,Half,MinDepth,MaxDepth) and
     FStatic[Zone].SameTexelSize(Half,FSize) then Inc(FStaticReuses)
  else begin
    FStatic[Zone].CaptureRegion(Render,FDirection,Side,Up,X,Y,Half,MinDepth,MaxDepth,FSize);
    Inc(FStaticCaptures);
  end;
  FStaticReady[Zone]:=True;
end;

procedure TTemporalWorldShadow.PrepareZone(Zone:Integer;
  const Render:TRenderFromViewFunction;const Side,Up:TVector3;
  X,Y,Half,MinDepth,MaxDepth:Single);
var B,OldCount,OldBucket:Integer;
begin
  if (FCount=0) or (Zone<FFirstZone) then Exit;
  B:=FBucket;
  if FMaps[Zone,B]=nil then FMaps[Zone,B]:=TShadowDepthCache.Create;
  OldCount:=ShadowCapturePartitions;OldBucket:=ShadowCapturePartition;
  ShadowCapturePartitions:=FCount;ShadowCapturePartition:=B;
  try
    if FFrameFrozen and (FAnimation[Zone,B]=FLastAnimation) and
       ((FTreeRevision[Zone,B]=FCurrentTreeRevision) or (FLastTick-FCaptureTick[Zone,B]<250)) and
       FMaps[Zone,B].Covers(FDirection,X,Y,Half,MinDepth,MaxDepth) and
       FMaps[Zone,B].SameTexelSize(Half,FSize) then Inc(FFrozenReuses)
    else begin
      FMaps[Zone,B].CaptureRegion(Render,FDirection,Side,Up,X,Y,Half,MinDepth,MaxDepth,FSize);
      FUpdated[Zone,B]:=FFrame;FAnimation[Zone,B]:=FLastAnimation;
      { Background detail generation can change a distant tree every frame.
        Coalesce representation-only changes on a 250 ms interval while wind
        is frozen, plus the bucket cadence. World membership/sun/coverage
        changes bypass this delay. }
      FTreeRevision[Zone,B]:=FCurrentTreeRevision;FCaptureTick[Zone,B]:=FLastTick;Inc(FCaptures);
    end;
  finally ShadowCapturePartitions:=OldCount;ShadowCapturePartition:=OldBucket;end;
  FReady[Zone]:=True;
  for B:=0 to FCount-1 do
    if (FMaps[Zone,B]=nil) or not FMaps[Zone,B].Covers(FDirection,X,Y,Half,MinDepth,MaxDepth) or
      not FMaps[Zone,B].SameTexelSize(Half,FSize) then
      FReady[Zone]:=False;
  if not FReady[Zone] then Inc(FFallbacks);
end;

function TTemporalWorldShadow.Ready(Zone:Integer):Boolean;
begin Result:=FReady[Zone];end;
function TTemporalWorldShadow.StaticReady(Zone:Integer):Boolean;
begin Result:=FStaticReady[Zone];end;

procedure TTemporalWorldShadow.SkipZone(Zone:Integer);
var B:Integer;
begin
  FReady[Zone]:=False;
  for B:=0 to 3 do FreeAndNil(FMaps[Zone,B]);
end;

procedure TTemporalWorldShadow.Draw(Zone:Integer;X,Y,Half,MinDepth,MaxDepth:Single);
var B,N:Integer;Sources:array[0..4]of TShadowDepthCache;
begin
  N:=0;
  if FStaticReady[Zone] then begin Sources[N]:=FStatic[Zone];Inc(N);end;
  if FReady[Zone] then
    for B:=0 to FCount-1 do begin Sources[N]:=FMaps[Zone,B];Inc(N);end;
  if N=0 then Exit;
  { All buckets/cascades share one linked program and VAO. Sources own only
    depth storage; they must not compile identical shaders per map. }
  if FCompositor=nil then FCompositor:=TShadowDepthCache.Create;
  if TemporalShadowSinglePass then begin
    FCompositor.DrawSources(Slice(Sources,N),X,Y,Half,MinDepth,MaxDepth);Inc(FComposeDraws);
  end else
    for B:=0 to N-1 do begin
      FCompositor.DrawSource(Sources[B],X,Y,Half,MinDepth,MaxDepth);Inc(FComposeDraws);
    end;
  Inc(FComposites);
end;

procedure TTemporalWorldShadow.Snapshot(J:TJSONObject);
var Z,B,Age:Integer;Bytes:Int64;Zones:TJSONArray;
begin
  Age:=0;Bytes:=0;Zones:=TJSONArray.Create;
  for Z:=0 to 3 do begin
    Zones.Add(FReady[Z]);
    if FStatic[Z]<>nil then Inc(Bytes,FStatic[Z].StorageBytes);
    for B:=0 to FCount-1 do if FMaps[Z,B]<>nil then begin
      Inc(Bytes,FMaps[Z,B].StorageBytes);
      if FReady[Z] then Age:=Max(Age,Integer(FFrame-FUpdated[Z,B]));
    end;
  end;
  J.Add('partitions',FCount);J.Add('updated_partition',FBucket);
  J.Add('max_age_frames',Age);J.Add('ready_zones',Zones);
  J.Add('captures',Int64(FCaptures));J.Add('composites',Int64(FComposites));
  J.Add('fallback_zones',Int64(FFallbacks));J.Add('depth_storage_bytes',Bytes);
  J.Add('live_near',FFirstZone=1);
  J.Add('separate_static',FSeparateStatic);J.Add('single_pass',TemporalShadowSinglePass);
  J.Add('static_captures',Int64(FStaticCaptures));J.Add('static_reuses',Int64(FStaticReuses));
  J.Add('frozen_reuses',Int64(FFrozenReuses));J.Add('compose_draws',Int64(FComposeDraws));
  J.Add('frozen_lod_delay_ms',250);
  J.Add('wind_frozen',FFrameFrozen);J.Add('wind_rate',VegetationWindRate);
  J.Add('wind_time',VegetationWindNow);J.Add('camera_speed_kmh',VegetationCameraSpeed*3.6);
  J.Add('moving_tree_distance',VegetationMotionAtlasDistance);
end;
end.
